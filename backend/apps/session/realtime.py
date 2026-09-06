import logging
import random

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.db import transaction
from django.db.models import Count

from apps.session.models import AnswerAttempt, FinalAnswer, LiveSession, SessionParticipant
from apps.session.results import build_leaderboard


EVENT_SCHEMA_VERSION = 2
SESSION_EVENT_ROLES = ('account', 'participant', 'display')
logger = logging.getLogger(__name__)


def session_group_name(session_id: int, access_type: str) -> str:
    return f'session_{session_id}_{access_type}'


def _current_run(session: LiveSession):
    if session.current_run_id is None:
        return None
    cached = session._state.fields_cache.get('current_run')
    if cached is not None and cached.pk == session.current_run_id:
        return cached
    return session.question_runs.get(pk=session.current_run_id)


def compute_question_ends_at(session: LiveSession, question):
    run = _current_run(session)
    if run is None or question is None or run.question_id != question.pk:
        return None
    return run.answer_deadline_at


def compute_phase_ends_at(session: LiveSession):
    run = _current_run(session)
    if run is None:
        return None
    return {
        LiveSession.PHASE_READING: run.reading_ends_at,
        LiveSession.PHASE_ANSWERING: run.answer_deadline_at,
        LiveSession.PHASE_DELIVERY: run.delivery_deadline_at,
        LiveSession.PHASE_RESULTS: run.results_ends_at,
    }.get(session.phase)


def _ordered_choices_for_session(question, session: LiveSession | None):
    choices = list(question.choices.all().order_by('order', 'id'))
    if session is None:
        return choices
    rng = random.Random(f'{session.id}:{question.id}:{session.join_token}')
    rng.shuffle(choices)
    return choices


def serialize_question_for_participants(question, session: LiveSession | None = None):
    if question is None:
        return None
    quiz = question.quiz_version
    show_question = not quiz.question_only_on_display
    show_choices = quiz.show_choices_on_participant
    return {
        'id': question.id,
        'text': question.text if show_question else '',
        'text_hidden': not show_question,
        'order': question.order,
        'time_limit_sec': question.time_limit_sec,
        'choices_text_hidden': not show_choices,
        'choices': [
            {
                'id': choice.id,
                'text': choice.text if show_choices else '',
                'order': index + 1,
                'original_order': choice.order,
            }
            for index, choice in enumerate(_ordered_choices_for_session(question, session))
        ],
    }


def serialize_question_for_display(question, session: LiveSession | None = None, *, include_correct: bool = False):
    if question is None:
        return None
    choices = []
    for index, choice in enumerate(_ordered_choices_for_session(question, session)):
        item = {
            'id': choice.id,
            'text': choice.text,
            'order': index + 1,
            'original_order': choice.order,
        }
        if include_correct:
            item['is_correct'] = choice.is_correct
        choices.append(item)
    return {
        'id': question.id,
        'text': question.text,
        'order': question.order,
        'time_limit_sec': question.time_limit_sec,
        'choices': choices,
    }


def _technical_question(question):
    if question is None:
        return None
    return {
        'id': question.pk,
        'text': question.text,
        'order': question.order,
        'time_limit_sec': question.time_limit_sec,
    }


def _base_state(session: LiveSession) -> dict:
    run = _current_run(session)
    phase_ends_at = compute_phase_ends_at(session)
    return {
        'schema_version': EVENT_SCHEMA_VERSION,
        'session_id': str(session.join_token),
        'status': session.status,
        'phase': session.phase,
        'state_revision': session.state_revision,
        'pin': session.pin,
        'participants_count': SessionParticipant.objects.filter(session=session).count(),
        'question_run_id': run.pk if run else None,
        'phase_started_at': session.phase_started_at.isoformat() if session.phase_started_at else None,
        'phase_ends_at': phase_ends_at.isoformat() if phase_ends_at else None,
        'answering_started_at': run.answering_started_at.isoformat() if run else None,
        'is_answer_revealed': bool(run and run.finalized_at),
        'reading_time_sec': session.quiz_version.reading_time_sec,
        'results_time_sec': session.quiz_version.results_time_sec,
    }


def build_account_session_state(session: LiveSession) -> dict:
    state = _base_state(session)
    state['current_question'] = _technical_question(session.current_question)
    run = _current_run(session)
    state['reading_ends_at'] = run.reading_ends_at.isoformat() if run else None
    state['answer_deadline_at'] = run.answer_deadline_at.isoformat() if run else None
    state['delivery_deadline_at'] = run.delivery_deadline_at.isoformat() if run else None
    state['results_ends_at'] = run.results_ends_at.isoformat() if run and run.results_ends_at else None
    if run and run.finalized_at:
        state['answered_participants_count'] = FinalAnswer.objects.filter(
            run=run,
            outcome=FinalAnswer.OUTCOME_ANSWERED,
        ).count()
    elif run:
        state['answered_participants_count'] = (
            AnswerAttempt.objects.filter(run=run)
            .values('session_participant_id')
            .distinct()
            .count()
        )
    else:
        state['answered_participants_count'] = 0
    if run and run.finalized_at:
        state['reveal'] = build_answer_reveal_payload(session, for_display=True)
    if session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}:
        state['leaderboard'] = build_leaderboard(session)
    return state


def _materialize_participant_attempts(
    run_id: int,
    participation_id: int,
) -> list[dict]:
    return list(
        AnswerAttempt.objects.filter(
            run_id=run_id,
            session_participant_id=participation_id,
        )
        .order_by('admitted_at', 'id')
        .values('ordinal', 'choice_id', 'admitted_at', 'id')[:20]
    )


def _participant_answer_state(session: LiveSession, participation_id: int | None):
    run = _current_run(session)
    if run is None or participation_id is None:
        return {'has_answer': False, 'selected_choice_id': None, 'answer_version': 0}
    attempts = _materialize_participant_attempts(run.pk, participation_id)
    answer_version = max((attempt['ordinal'] for attempt in attempts), default=0)
    latest = attempts[-1] if attempts else None
    if run.finalized_at:
        final = FinalAnswer.objects.filter(run=run, session_participant_id=participation_id).first()
        if final is None:
            return {
                'has_answer': False,
                'selected_choice_id': None,
                'answer_version': answer_version,
                'final': None,
            }
        return {
            'has_answer': final.outcome == FinalAnswer.OUTCOME_ANSWERED,
            'selected_choice_id': final.selected_attempt.choice_id if final.selected_attempt_id else None,
            'answer_version': answer_version,
            'final': {
                'outcome': final.outcome,
                'choice_id': final.selected_attempt.choice_id if final.selected_attempt_id else None,
                'is_correct': final.is_correct,
                'actual_elapsed_ms': final.actual_elapsed_ms,
                'ranking_elapsed_ms': final.ranking_elapsed_ms,
            },
        }
    result = {
        'has_answer': latest is not None,
        'selected_choice_id': latest['choice_id'] if latest else None,
        'answer_version': answer_version,
    }
    return result


def build_participant_session_state(session: LiveSession, participation_id: int | None = None) -> dict:
    state = _base_state(session)
    state['current_question'] = serialize_question_for_participants(session.current_question, session)
    state['answer'] = _participant_answer_state(session, participation_id)
    run = _current_run(session)
    if run and run.finalized_at:
        state['reveal'] = build_answer_reveal_payload(session)
    if session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}:
        state['leaderboard'] = build_leaderboard(session)
    return state


def build_public_session_state(session: LiveSession) -> dict:
    """Совместимый псевдоним безопасного снимка участника без личного контекста."""
    return build_participant_session_state(session)


def build_public_leaderboard(session: LiveSession) -> list[dict]:
    return build_leaderboard(session)


def get_next_question(session: LiveSession):
    questions = list(session.quiz_version.questions.all().order_by('order', 'id'))
    if session.current_question_id is None:
        return questions[0] if questions else None
    for index, question in enumerate(questions):
        if question.pk == session.current_question_id:
            return questions[index + 1] if index + 1 < len(questions) else None
    return None


def build_answer_reveal_payload(session: LiveSession, *, for_display: bool = False) -> dict:
    question = session.current_question
    run = _current_run(session)
    if question is None or run is None or run.finalized_at is None:
        return {
            'session_id': str(session.join_token),
            'phase': session.phase,
            'question': None,
            'choices': [],
            'total_answers': 0,
        }
    counts = (
        FinalAnswer.objects.filter(run=run, selected_attempt__isnull=False)
        .values('selected_attempt__choice_id')
        .annotate(total=Count('id'))
    )
    by_choice = {item['selected_attempt__choice_id']: item['total'] for item in counts}
    total_answers = sum(by_choice.values())
    show_choices = for_display or session.quiz_version.show_choices_on_participant
    choices = []
    for index, choice in enumerate(_ordered_choices_for_session(question, session)):
        answers_count = by_choice.get(choice.pk, 0)
        choices.append({
            'id': choice.pk,
            'text': choice.text if show_choices else '',
            'order': index + 1,
            'original_order': choice.order,
            'is_correct': choice.is_correct,
            'answers_count': answers_count,
            'answers_percent': round((answers_count / total_answers) * 100) if total_answers else 0,
        })
    return {
        'session_id': str(session.join_token),
        'status': session.status,
        'phase': session.phase,
        'state_revision': session.state_revision,
        'question': {
            'id': question.pk,
            'text': question.text if (for_display or not session.quiz_version.question_only_on_display) else '',
            'text_hidden': not for_display and session.quiz_version.question_only_on_display,
            'order': question.order,
            'time_limit_sec': question.time_limit_sec,
        },
        'choices': choices,
        'total_answers': total_answers,
        'leaderboard': build_leaderboard(session),
    }


def build_display_session_state(session: LiveSession) -> dict:
    state = _base_state(session)
    run = _current_run(session)
    state['display_question'] = serialize_question_for_display(
        session.current_question,
        session,
        include_correct=bool(run and run.finalized_at),
    )
    state['quiz'] = {
        'id': session.quiz_version.quiz_id,
        'title': session.quiz_version.title,
        'description': session.quiz_version.description,
        'reading_time_sec': session.quiz_version.reading_time_sec,
        'results_time_sec': session.quiz_version.results_time_sec,
        'question_only_on_display': session.quiz_version.question_only_on_display,
        'show_choices_on_participant': session.quiz_version.show_choices_on_participant,
    }
    if run and run.finalized_at:
        state['reveal'] = build_answer_reveal_payload(session, for_display=True)
    if session.status in {LiveSession.STATUS_FINISHED, LiveSession.STATUS_ABORTED}:
        state['leaderboard'] = build_leaderboard(session)
    return state


def broadcast_session_event(
    session_id: int,
    event: str,
    payload: dict,
    *,
    roles: tuple[str, ...] | None = None,
) -> None:
    """После фиксации передать только имя события; снимок перечитывает получатель."""
    target_roles = SESSION_EVENT_ROLES if roles is None else tuple(roles)
    unknown_roles = set(target_roles) - set(SESSION_EVENT_ROLES)
    if unknown_roles:
        raise ValueError('Указана недопустимая роль получателя события сессии.')

    def send():
        try:
            channel_layer = get_channel_layer()
        except Exception:
            logger.error('Не удалось подготовить канал событий сессии.')
            return
        if channel_layer is None:
            return
        for role in target_roles:
            try:
                async_to_sync(channel_layer.group_send)(
                    session_group_name(session_id, role),
                    {'type': 'session.event', 'event': event, 'schema_version': EVENT_SCHEMA_VERSION},
                )
            except Exception:
                logger.error('Не удалось отправить событие сессии для роли «%s».', role)

    transaction.on_commit(send, robust=True)
