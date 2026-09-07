from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar

from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import Prefetch, Q, Subquery
from django.utils import timezone
from rest_framework.exceptions import PermissionDenied

from apps.core.errors import (
    Conflict,
    QuizArchivedConflict,
    QuizHistoryProtected,
    QuizNotFound,
    QuizOpenSessionConflict,
    QuizRevisionConflict,
)
from apps.core.permissions import can_manage_quiz, is_admin, is_teacher
from apps.quiz.models import Choice, Question, Quiz, QuizVersion
from apps.quiz.validation import quiz_data, validate_quiz_data


_CONTENT_WRITE_DEPTH = ContextVar('quiz_content_write_depth', default=0)
CONTENT_FIELDS = (
    'title',
    'description',
    'question_only_on_display',
    'show_choices_on_participant',
    'reading_time_sec',
    'results_time_sec',
)


def _quiz_content_write_allowed() -> bool:
    """Сообщить моделям, что запись выполняет доверенный прикладной сервис."""
    return _CONTENT_WRITE_DEPTH.get() > 0


@contextmanager
def _quiz_content_write():
    token = _CONTENT_WRITE_DEPTH.set(_CONTENT_WRITE_DEPTH.get() + 1)
    try:
        yield
    finally:
        _CONTENT_WRITE_DEPTH.reset(token)


def _with_version_content(queryset):
    return queryset.prefetch_related(
        Prefetch(
            'questions',
            queryset=Question.objects.order_by('order', 'id').prefetch_related(
                Prefetch(
                    'choices',
                    queryset=Choice.objects.order_by('order', 'id'),
                )
            ),
        )
    )


def effective_version_prefetch() -> Prefetch:
    """Загрузить для каждой карточки только её эффективную версию."""
    return Prefetch(
        'versions',
        queryset=_with_version_content(
            QuizVersion.objects.order_by('-number', '-id')[:1]
        ),
        to_attr='_effective_versions',
    )


def get_effective_version(quiz: Quiz) -> QuizVersion | None:
    """Вернуть редактируемый черновик, иначе последнюю зафиксированную версию."""
    prefetched = getattr(quiz, '_effective_versions', None)
    if prefetched is not None:
        return prefetched[0] if prefetched else None
    return _with_version_content(
        quiz.versions.order_by('-number', '-id')
    ).first()


def lock_relevant_versions(
    quiz: Quiz,
) -> tuple[QuizVersion | None, QuizVersion | None]:
    """Заблокировать черновик и последнюю фиксацию карточки с их содержимым."""
    latest_fixed_id = (
        QuizVersion.objects.filter(
            quiz=quiz,
            status=QuizVersion.STATUS_FIXED,
        )
        .order_by('-number', '-id')
        .values('pk')[:1]
    )
    versions = list(
        _with_version_content(
            QuizVersion.objects.select_for_update()
            .filter(
                Q(quiz=quiz, status=QuizVersion.STATUS_DRAFT)
                | Q(pk=Subquery(latest_fixed_id))
            )
            .order_by('number', 'id')
        )
    )
    draft = next(
        (version for version in versions if version.status == QuizVersion.STATUS_DRAFT),
        None,
    )
    fixed = [
        version for version in versions if version.status == QuizVersion.STATUS_FIXED
    ]
    return draft, (fixed[-1] if fixed else None)


def version_data(version: QuizVersion) -> dict:
    """Материализовать полный публичный снимок содержимого версии."""
    return quiz_data(version)


def _canonical(data: dict) -> dict:
    return {
        **{field: data[field] for field in CONTENT_FIELDS},
        'questions': [
            {
                'text': question['text'],
                'order': question['order'],
                'time_limit_sec': question['time_limit_sec'],
                'choices': [
                    {
                        'text': choice['text'],
                        'is_correct': choice['is_correct'],
                        'order': choice['order'],
                    }
                    for choice in question['choices']
                ],
            }
            for question in data['questions']
        ],
    }


def versions_have_equal_content(left: QuizVersion, right: QuizVersion) -> bool:
    return _canonical(version_data(left)) == _canonical(version_data(right))


def _merge_content(base: dict | None, changes: dict) -> dict:
    base = base or {}
    merged = {
        field: changes.get(field, base.get(field, default))
        for field, default in (
            ('title', ''),
            ('description', ''),
            ('question_only_on_display', False),
            ('show_choices_on_participant', True),
            ('reading_time_sec', 15),
            ('results_time_sec', 10),
        )
    }
    if 'questions' not in changes:
        merged['questions'] = base.get('questions', [])
        return merged

    old_questions = {
        question['id']: question
        for question in base.get('questions', [])
        if question.get('id') is not None
    }
    seen_question_ids = set()
    questions = []
    for question_index, source in enumerate(changes['questions']):
        source = dict(source)
        question_id = source.get('id')
        if question_id is not None:
            if question_id in seen_question_ids or question_id not in old_questions:
                raise ValidationError({
                    f'questions.{question_index}.id': (
                        'Вопрос не принадлежит текущему черновику или повторяется.'
                    )
                })
            seen_question_ids.add(question_id)
        old_question = old_questions.get(question_id, {})
        question = {
            'time_limit_sec': 20,
            **old_question,
            **source,
            'order': question_index + 1,
        }
        if 'choices' not in source:
            question['choices'] = old_question.get('choices', [])
        else:
            old_choices = {
                choice['id']: choice
                for choice in old_question.get('choices', [])
                if choice.get('id') is not None
            }
            seen_choice_ids = set()
            choices = []
            for choice_index, choice_source in enumerate(source['choices']):
                choice_source = dict(choice_source)
                choice_id = choice_source.get('id')
                if choice_id is not None:
                    if choice_id in seen_choice_ids or choice_id not in old_choices:
                        raise ValidationError({
                            f'questions.{question_index}.choices.{choice_index}.id': (
                                'Вариант не принадлежит указанному вопросу или повторяется.'
                            )
                        })
                    seen_choice_ids.add(choice_id)
                choices.append({
                    'is_correct': False,
                    **old_choices.get(choice_id, {}),
                    **choice_source,
                    'order': choice_index + 1,
                })
            question['choices'] = choices
        questions.append(question)
    merged['questions'] = questions
    return merged


def _create_version_graph(quiz: Quiz, number: int, data: dict) -> QuizVersion:
    version = QuizVersion(
        quiz=quiz,
        number=number,
        status=QuizVersion.STATUS_DRAFT,
        **{field: data[field] for field in CONTENT_FIELDS},
    )
    version.save(force_insert=True)
    for question_data in data['questions']:
        choices = question_data['choices']
        question = Question(
            quiz_version=version,
            **{
                field: question_data[field]
                for field in ('text', 'order', 'time_limit_sec')
            },
        )
        question.save(force_insert=True)
        for choice_data in choices:
            Choice(question=question, **{
                field: choice_data[field]
                for field in ('text', 'is_correct', 'order')
            }).save(force_insert=True)
    return version


def _update_draft_graph(version: QuizVersion, data: dict) -> None:
    for field in CONTENT_FIELDS:
        setattr(version, field, data[field])
    version.save(update_fields=[*CONTENT_FIELDS, 'updated_at'])

    retained_questions = []
    existing_questions = {
        question.pk: question
        for question in version.questions.all()
    }
    for question_data in data['questions']:
        choices_data = question_data['choices']
        question_id = question_data.get('id')
        question = (
            existing_questions[question_id]
            if question_id is not None
            else Question(quiz_version=version)
        )
        existing_choices = {
            choice.pk: choice
            for choice in question.choices.all()
        } if question_id is not None else {}
        for field in ('text', 'order', 'time_limit_sec'):
            setattr(question, field, question_data[field])
        question.save()
        retained_questions.append(question.pk)

        retained_choices = []
        for choice_data in choices_data:
            choice_id = choice_data.get('id')
            choice = (
                existing_choices[choice_id]
                if choice_id is not None
                else Choice(question=question)
            )
            for field in ('text', 'is_correct', 'order'):
                setattr(choice, field, choice_data[field])
            choice.save()
            retained_choices.append(choice.pk)
        question.choices.exclude(pk__in=retained_choices).delete()
    version.questions.exclude(pk__in=retained_questions).delete()


@transaction.atomic
def create_quiz_with_draft(*, actor, data: dict) -> Quiz:
    """Создать стабильную карточку и первую редактируемую версию одной транзакцией."""
    if not (is_admin(actor) or is_teacher(actor)):
        raise PermissionDenied('Требуются права преподавателя или администратора.')
    content = _merge_content(None, data)
    validate_quiz_data(content)
    with _quiz_content_write():
        quiz = Quiz(owner=actor, content_revision=1)
        quiz.save(force_insert=True)
        _create_version_graph(quiz, 1, content)
    return quiz


def _lock_quiz_or_not_found(quiz_id: int) -> Quiz:
    """Заблокировать существующую карточку или вернуть прикладной ответ 404."""
    try:
        return Quiz.objects.select_for_update().get(pk=quiz_id)
    except Quiz.DoesNotExist:
        raise QuizNotFound() from None


@transaction.atomic
def save_quiz_content(
    *,
    quiz_id: int,
    actor,
    expected_revision: int,
    data: dict,
) -> Quiz:
    """Сохранить содержимое с блокировкой карточки и проверкой редакции."""
    quiz = _lock_quiz_or_not_found(quiz_id)
    if not can_manage_quiz(actor, quiz):
        raise PermissionDenied('Нет прав на изменение этой викторины.')
    if quiz.archived_at is not None:
        raise QuizArchivedConflict('Архивную викторину нельзя изменять.')
    if quiz.content_revision != expected_revision:
        raise QuizRevisionConflict(quiz.content_revision)

    draft, latest_fixed = lock_relevant_versions(quiz)
    base = draft or latest_fixed
    if base is None:
        raise Conflict('У викторины отсутствует версия содержимого.')

    current_data = version_data(base)
    content = _merge_content(current_data, data)
    validate_quiz_data(content)
    if _canonical(content) == _canonical(current_data):
        return quiz

    with _quiz_content_write():
        if draft is not None:
            _update_draft_graph(draft, content)
        else:
            next_number = latest_fixed.number + 1
            _create_version_graph(quiz, next_number, content)
        quiz.content_revision += 1
        quiz.save(update_fields=['content_revision', 'updated_at'])
    return quiz


def _lock_quiz_sessions(quiz: Quiz, *, statuses=None) -> list[int]:
    """Заблокировать связанные сессии в устойчивом порядке и вернуть их id."""
    from apps.session.models import LiveSession

    sessions = LiveSession.objects.select_for_update(of=('self',)).filter(
        quiz_version__quiz=quiz,
    )
    if statuses is not None:
        sessions = sessions.filter(status__in=statuses)
    return list(sessions.order_by('pk').values_list('pk', flat=True))


def _archive_quiz_lock_barrier() -> None:
    """Точка синхронизации конкурентных проверок после блокировки карточки."""


@transaction.atomic
def archive_quiz(*, quiz_id: int, actor) -> Quiz:
    """Архивировать карточку, если у всех её версий нет открытых сессий."""
    from apps.session.models import LiveSession

    quiz = _lock_quiz_or_not_found(quiz_id)
    if not can_manage_quiz(actor, quiz):
        raise PermissionDenied('Нет прав на архивирование этой викторины.')
    if quiz.archived_at is not None:
        return quiz
    _archive_quiz_lock_barrier()
    if _lock_quiz_sessions(
        quiz,
        statuses=(LiveSession.STATUS_WAITING, LiveSession.STATUS_LIVE),
    ):
        raise QuizOpenSessionConflict()

    with _quiz_content_write():
        quiz.archived_at = timezone.now()
        quiz.save(update_fields=['archived_at', 'updated_at'])
    return quiz


@transaction.atomic
def restore_quiz(*, quiz_id: int, actor) -> Quiz:
    """Вернуть архивную карточку в рабочий список без изменения её версий."""
    quiz = _lock_quiz_or_not_found(quiz_id)
    if not can_manage_quiz(actor, quiz):
        raise PermissionDenied('Нет прав на восстановление этой викторины.')
    if quiz.archived_at is None:
        return quiz

    with _quiz_content_write():
        quiz.archived_at = None
        quiz.save(update_fields=['archived_at', 'updated_at'])
    return quiz


@transaction.atomic
def delete_quiz(*, quiz_id: int, actor) -> None:
    """Физически удалить только карточку, не связанную ни с одной сессией."""
    quiz = _lock_quiz_or_not_found(quiz_id)
    if not can_manage_quiz(actor, quiz):
        raise PermissionDenied('Нет прав на удаление этой викторины.')
    if _lock_quiz_sessions(quiz):
        raise QuizHistoryProtected()

    with _quiz_content_write():
        quiz.delete()
