from __future__ import annotations

import hashlib
import json
import uuid
from collections import defaultdict
from datetime import timedelta

from django.db import connection, transaction
from rest_framework import serializers

from apps.core.errors import Conflict, StateConflict
from apps.quiz.models import Choice
from apps.session.models import (
    AnswerAttempt,
    FinalAnswer,
    LiveSession,
    SessionCommand,
    SessionParticipant,
    SessionQuestionRun,
)


DELIVERY_WINDOW_SECONDS = 3
AUTOMATIC_COMMAND_NAMESPACE = uuid.UUID('1129afec-87e7-4ddc-929d-42b3667ec249')


def _answer_run_lock_barrier():
    """Точка управляемого барьера конкурентного теста; в работе ничего не делает."""


def _finalizer_run_lock_barrier():
    """Точка управляемого барьера конкурентного теста; в работе ничего не делает."""


def _answer_participant_lock_barrier(participation_id: int):
    """Точка управляемого барьера после блокировки участия; в работе ничего не делает."""


def _advance_preflight_barrier():
    """Точка управляемого барьера после неблокирующего чтения; в работе ничего не делает."""


def database_now():
    """Получить фактический момент из PostgreSQL для игровых границ."""
    with connection.cursor() as cursor:
        cursor.execute('SELECT clock_timestamp()')
        return cursor.fetchone()[0]


def _digest(payload: dict) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(encoded).hexdigest()


def _lock_trusted_current_run_for_answer(session_id: int, question_id: int):
    """Проверить серверный контекст и блокировать только строку текущего запуска."""
    with connection.cursor() as cursor:
        cursor.execute(
            '''
            SELECT
                run.id,
                run.question_id,
                run.answering_started_at,
                run.answer_deadline_at,
                run.delivery_deadline_at,
                run.finalized_at
            FROM session_sessionquestionrun AS run
            INNER JOIN session_livesession AS live
                ON live.current_run_id = run.id
            WHERE live.id = %s
              AND live.gameplay_schema = %s
              AND live.status = %s
              AND live.phase IN (%s, %s, %s)
              AND live.current_question_id = %s
              AND run.session_id = live.id
              AND run.question_id = %s
            FOR SHARE OF run
            ''',
            [
                session_id,
                LiveSession.GAMEPLAY_SCHEMA_V2,
                LiveSession.STATUS_LIVE,
                LiveSession.PHASE_ANSWERING,
                LiveSession.PHASE_DELIVERY,
                LiveSession.PHASE_RESULTS,
                question_id,
                question_id,
            ],
        )
        return cursor.fetchone()


@transaction.atomic
def record_answer_attempt(
    *,
    session_id: int,
    participation_id: int,
    question_id: int,
    choice_id: int,
    submission_id: uuid.UUID,
) -> tuple[AnswerAttempt | None, bool]:
    """Записать уникальное нажатие; внутренний результат не раскрывается HTTP-клиенту."""
    run_row = _lock_trusted_current_run_for_answer(session_id, question_id)
    if run_row is None:
        raise Conflict('Этот вопрос не является текущим вопросом активной сессии.')

    run_id = run_row[0]
    _answer_run_lock_barrier()
    admitted_at = database_now()
    if not LiveSession.objects.filter(
        pk=session_id,
        status=LiveSession.STATUS_LIVE,
        current_run_id=run_id,
        current_question_id=question_id,
    ).exists():
        raise Conflict('Сессия больше не принимает попытки этого вопроса.')
    try:
        participation = SessionParticipant.objects.select_for_update().get(
            pk=participation_id,
            session_id=session_id,
        )
    except SessionParticipant.DoesNotExist as exc:
        raise Conflict('Токен участия не соответствует этой сессии.') from exc
    _answer_participant_lock_barrier(participation.pk)

    try:
        choice = Choice.objects.get(pk=choice_id, question_id=question_id)
    except Choice.DoesNotExist as exc:
        raise serializers.ValidationError({'choice_id': 'Вариант не принадлежит текущему вопросу.'}) from exc

    payload_digest = _digest({'question_id': question_id, 'choice_id': choice_id})
    existing = AnswerAttempt.objects.filter(
        run_id=run_id,
        session_participant=participation,
        submission_id=submission_id,
    ).first()
    if existing is not None:
        if existing.payload_digest != payload_digest:
            raise Conflict('Идентификатор нажатия уже использован для другого ответа.')
        return existing, True

    attempts_count = AnswerAttempt.objects.filter(
        run_id=run_id,
        session_participant=participation,
    ).count()
    if attempts_count >= 20:
        return None, False

    attempt = AnswerAttempt.objects.create(
        run_id=run_id,
        session_participant=participation,
        choice=choice,
        submission_id=submission_id,
        payload_digest=payload_digest,
        admitted_at=admitted_at,
        ordinal=attempts_count + 1,
    )
    from apps.session.realtime import broadcast_session_event
    broadcast_session_event(session_id, 'answer_state_changed', {}, roles=('account',))
    return attempt, False


def _basic_state(session: LiveSession) -> dict:
    run = session.current_run if session.current_run_id else None
    return {
        'session_id': str(session.join_token),
        'status': session.status,
        'phase': session.phase,
        'state_revision': session.state_revision,
        'question_id': session.current_question_id,
        'question_run_id': session.current_run_id,
        'reading_ends_at': run.reading_ends_at.isoformat() if run else None,
        'answer_deadline_at': run.answer_deadline_at.isoformat() if run else None,
        'delivery_deadline_at': run.delivery_deadline_at.isoformat() if run else None,
        'results_ends_at': run.results_ends_at.isoformat() if run and run.results_ends_at else None,
    }


def _conflict(message: str, session: LiveSession):
    raise StateConflict(message, _basic_state(session))


def _next_question(session: LiveSession):
    questions = list(session.quiz.questions.all().order_by('order', 'id'))
    if session.current_question_id is None:
        return questions[0] if questions else None
    for index, question in enumerate(questions):
        if question.pk == session.current_question_id:
            return questions[index + 1] if index + 1 < len(questions) else None
    return None


def _lock_current_run(session: LiveSession):
    if session.current_run_id is None:
        return None
    run = SessionQuestionRun.objects.select_for_update().select_related('question').get(
        pk=session.current_run_id,
        session=session,
    )
    session.current_run = run
    return run


def _save_session(session: LiveSession, *fields: str):
    session.state_revision += 1
    session.save(update_fields=[*fields, 'state_revision'])


def _start_question(session: LiveSession, question, now) -> str:
    reading_ends_at = now + timedelta(seconds=session.quiz.reading_time_sec)
    answer_deadline_at = reading_ends_at + timedelta(seconds=question.time_limit_sec)
    delivery_deadline_at = answer_deadline_at + timedelta(seconds=DELIVERY_WINDOW_SECONDS)
    run = SessionQuestionRun.objects.create(
        session=session,
        question=question,
        ordinal=session.question_runs.count() + 1,
        reading_started_at=now,
        reading_ends_at=reading_ends_at,
        answering_started_at=reading_ends_at,
        planned_answer_deadline_at=answer_deadline_at,
        planned_delivery_deadline_at=delivery_deadline_at,
        answer_deadline_at=answer_deadline_at,
        delivery_deadline_at=delivery_deadline_at,
    )
    session.current_question = question
    session.current_run = run
    session.revealed_question_id = None
    session.phase = LiveSession.PHASE_READING
    session.phase_started_at = now
    session.question_started_at = run.answering_started_at
    _save_session(
        session,
        'current_question',
        'current_run',
        'revealed_question_id',
        'phase',
        'phase_started_at',
        'question_started_at',
    )
    return 'question_reading_started'


def _finish_session(session: LiveSession, now, *, aborted: bool) -> str:
    _lock_current_run(session)
    session.status = LiveSession.STATUS_ABORTED if aborted else LiveSession.STATUS_FINISHED
    session.phase = LiveSession.PHASE_FINAL
    session.current_question = None
    session.current_run = None
    session.revealed_question_id = None
    session.phase_started_at = now
    session.question_started_at = None
    session.finished_at = now
    _save_session(
        session,
        'status',
        'phase',
        'current_question',
        'current_run',
        'revealed_question_id',
        'phase_started_at',
        'question_started_at',
        'finished_at',
    )
    return 'session_aborted' if aborted else 'session_finished'


def _select_final_attempts(attempts: list[AnswerAttempt]):
    if not attempts:
        return None, None
    selected = attempts[-1]
    timing = selected
    for attempt in reversed(attempts[:-1]):
        if attempt.choice_id != selected.choice_id:
            break
        timing = attempt
    return selected, timing


def _finalize_locked(session: LiveSession, run: SessionQuestionRun, now) -> str | None:
    _finalizer_run_lock_barrier()
    if run.finalized_at is not None:
        return None
    if now <= run.delivery_deadline_at:
        return None

    attempts_by_participant = defaultdict(list)
    attempts = (
        AnswerAttempt.objects.filter(run=run, admitted_at__lte=run.delivery_deadline_at)
        .select_related('choice')
        .order_by('session_participant_id', 'admitted_at', 'id')
    )
    for attempt in attempts:
        attempts_by_participant[attempt.session_participant_id].append(attempt)

    answer_window_ms = int(
        max(0, (run.answer_deadline_at - run.answering_started_at).total_seconds() * 1000)
    )
    participants = SessionParticipant.objects.filter(session=session).order_by('pk')
    for participant in participants:
        selected, timing = _select_final_attempts(attempts_by_participant[participant.pk])
        if selected is None:
            FinalAnswer.objects.create(
                run=run,
                session_participant=participant,
                outcome=FinalAnswer.OUTCOME_UNANSWERED,
                is_correct=False,
                finalized_at=now,
            )
            continue
        actual_elapsed_ms = int(
            max(0, (timing.admitted_at - run.answering_started_at).total_seconds() * 1000)
        )
        FinalAnswer.objects.create(
            run=run,
            session_participant=participant,
            selected_attempt=selected,
            timing_attempt=timing,
            outcome=FinalAnswer.OUTCOME_ANSWERED,
            is_correct=selected.choice.is_correct,
            actual_elapsed_ms=actual_elapsed_ms,
            ranking_elapsed_ms=min(actual_elapsed_ms, answer_window_ms),
            finalized_at=now,
        )

    run.finalized_at = now
    run.results_started_at = now
    run.results_ends_at = now + timedelta(seconds=session.quiz.results_time_sec)
    run.save(update_fields=['finalized_at', 'results_started_at', 'results_ends_at'])
    session.phase = LiveSession.PHASE_RESULTS
    session.revealed_question_id = run.question_id
    session.phase_started_at = now
    _save_session(session, 'phase', 'revealed_question_id', 'phase_started_at')
    return 'question_results_opened'


def _apply_transition(session: LiveSession, kind: str, now) -> str:
    if kind == 'start_session':
        if session.status != LiveSession.STATUS_WAITING or session.phase != LiveSession.PHASE_LOBBY:
            _conflict('Сессию можно начать только из открытого лобби.', session)
        session.status = LiveSession.STATUS_LIVE
        session.started_at = now
        _save_session(session, 'status', 'started_at')
        return 'session_started'

    if kind == 'start_quiz':
        if session.status != LiveSession.STATUS_LIVE or session.phase != LiveSession.PHASE_LOBBY:
            _conflict('Викторину можно начать только после запуска сессии.', session)
        question = _next_question(session)
        if question is None:
            _conflict('В викторине нет вопроса для запуска.', session)
        return _start_question(session, question, now)

    if kind == 'end_question':
        if session.status != LiveSession.STATUS_LIVE or session.phase != LiveSession.PHASE_ANSWERING:
            _conflict('Досрочно завершить можно только этап приёма ответов.', session)
        run = _lock_current_run(session)
        if run is None or run.finalized_at is not None:
            _conflict('Нет активного запуска вопроса.', session)
        if now >= run.planned_answer_deadline_at:
            _conflict('Основной срок уже истёк; состояние обновит серверный таймер.', session)
        run.answer_deadline_at = now
        run.delivery_deadline_at = now + timedelta(seconds=DELIVERY_WINDOW_SECONDS)
        run.save(update_fields=['answer_deadline_at', 'delivery_deadline_at'])
        session.phase = LiveSession.PHASE_DELIVERY
        session.phase_started_at = now
        _save_session(session, 'phase', 'phase_started_at')
        return 'answer_delivery_started'

    if kind == 'next_question':
        if session.status != LiveSession.STATUS_LIVE or session.phase != LiveSession.PHASE_RESULTS:
            _conflict('Следующий вопрос можно открыть только из результатов.', session)
        run = _lock_current_run(session)
        if run is None or run.finalized_at is None:
            _conflict('Текущий вопрос ещё не финализирован.', session)
        question = _next_question(session)
        if question is None:
            _conflict('Это последний вопрос; сессию завершит срок результатов.', session)
        return _start_question(session, question, now)

    if kind == 'abort_session':
        if session.status not in {LiveSession.STATUS_WAITING, LiveSession.STATUS_LIVE}:
            _conflict('Завершённую или остановленную сессию нельзя остановить повторно.', session)
        return _finish_session(session, now, aborted=True)

    _conflict('Неизвестная управляющая команда.', session)


@transaction.atomic
def execute_manual_command(session_id: int, kind: str, data: dict) -> tuple[dict, bool]:
    """Применить ручную команду один раз и вернуть состояние и признак повтора."""
    session = (
        LiveSession.objects.select_for_update(of=('self',))
        .select_related('quiz', 'current_question', 'current_run')
        .get(pk=session_id)
    )
    request_facts = {
        'kind': kind,
        'state_revision': data['state_revision'],
        'phase': data['phase'],
        'question_run_id': data.get('question_run_id'),
    }
    payload_digest = _digest(request_facts)
    existing = SessionCommand.objects.filter(session=session, command_id=data['command_id']).first()
    if existing is not None:
        if (
            existing.kind != kind
            or existing.expected_revision != data['state_revision']
            or existing.payload_digest != payload_digest
        ):
            _conflict('Идентификатор команды уже использован для другого запроса.', session)
        return existing.response, True

    if session.state_revision != data['state_revision']:
        _conflict('Версия состояния устарела.', session)
    if session.phase != data['phase'] or session.current_run_id != data.get('question_run_id'):
        _conflict('Контекст этапа или запуска вопроса устарел.', session)

    now = database_now()
    event = _apply_transition(session, kind, now)
    response = _basic_state(session)
    SessionCommand.objects.create(
        session=session,
        command_id=data['command_id'],
        kind=kind,
        expected_revision=data['state_revision'],
        payload_digest=payload_digest,
        applied_revision=session.state_revision,
        response=response,
    )
    from apps.session.realtime import broadcast_session_event
    broadcast_session_event(session.pk, event, {})
    return response, False


def _automatic_command_id(session: LiveSession, kind: str, boundary) -> uuid.UUID:
    run_id = session.current_run_id or 0
    return uuid.uuid5(
        AUTOMATIC_COMMAND_NAMESPACE,
        f'{session.pk}:{run_id}:{kind}:{boundary.isoformat()}',
    )


def _transition_may_be_due(session: LiveSession, run: SessionQuestionRun | None, now) -> bool:
    """Без блокировок определить, мог ли наступить один серверный переход."""
    if run is not None and run.finalized_at is None and now > run.delivery_deadline_at:
        return True
    if session.phase == LiveSession.PHASE_READING and run is not None:
        return now >= run.reading_ends_at
    if session.phase == LiveSession.PHASE_ANSWERING and run is not None:
        return now >= run.answer_deadline_at
    if session.phase == LiveSession.PHASE_RESULTS and run is not None and run.results_ends_at is not None:
        return now >= run.results_ends_at
    return False


def advance_one_transition(session_id: int, *, now=None) -> tuple[LiveSession, bool]:
    """Восстановить не более одного устойчивого состояния по сохранённым срокам."""
    session = (
        LiveSession.objects.select_related('quiz', 'current_question', 'current_run')
        .get(pk=session_id)
    )
    if session.status != LiveSession.STATUS_LIVE:
        return session, False
    now = now or database_now()
    run = session.current_run if session.current_run_id else None
    _advance_preflight_barrier()
    if not _transition_may_be_due(session, run, now):
        return session, False

    with transaction.atomic():
        session = (
            LiveSession.objects.select_for_update(of=('self',))
            .select_related('quiz', 'current_question', 'current_run')
            .get(pk=session_id)
        )
        if session.status != LiveSession.STATUS_LIVE:
            return session, False
        run = _lock_current_run(session)
        if not _transition_may_be_due(session, run, now):
            return session, False

        kind = None
        boundary = None
        event = None

        if run is not None and run.finalized_at is None and now > run.delivery_deadline_at:
            kind = 'auto_finalize_question'
            boundary = run.delivery_deadline_at
            event = _finalize_locked(session, run, now)
        elif session.phase == LiveSession.PHASE_READING and run is not None and now >= run.reading_ends_at:
            kind = 'auto_start_answering'
            boundary = run.reading_ends_at
            session.phase = LiveSession.PHASE_ANSWERING
            session.phase_started_at = run.answering_started_at
            session.question_started_at = run.answering_started_at
            _save_session(session, 'phase', 'phase_started_at', 'question_started_at')
            event = 'question_answering_started'
        elif session.phase == LiveSession.PHASE_ANSWERING and run is not None and now >= run.answer_deadline_at:
            kind = 'auto_start_delivery'
            boundary = run.answer_deadline_at
            session.phase = LiveSession.PHASE_DELIVERY
            session.phase_started_at = run.answer_deadline_at
            _save_session(session, 'phase', 'phase_started_at')
            event = 'answer_delivery_started'
        elif (
            session.phase == LiveSession.PHASE_RESULTS
            and run is not None
            and run.results_ends_at is not None
            and now >= run.results_ends_at
        ):
            boundary = run.results_ends_at
            question = _next_question(session)
            if question is None:
                kind = 'auto_finish_session'
                event = _finish_session(session, now, aborted=False)
            else:
                kind = 'auto_next_question'
                event = _start_question(session, question, now)

        if kind is None or event is None:
            return session, False

        command_id = _automatic_command_id(session, kind, boundary)
        request_facts = {
            'kind': kind,
            'state_revision': session.state_revision - 1,
            'phase': None,
            'question_run_id': run.pk if run else None,
            'boundary': boundary.isoformat(),
        }
        SessionCommand.objects.create(
            session=session,
            command_id=command_id,
            kind=kind,
            expected_revision=session.state_revision - 1,
            payload_digest=_digest(request_facts),
            applied_revision=session.state_revision,
            response=_basic_state(session),
        )
        from apps.session.realtime import broadcast_session_event
        broadcast_session_event(session.pk, event, {})
        return session, True
