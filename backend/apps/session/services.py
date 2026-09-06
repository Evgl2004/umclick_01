from contextlib import contextmanager
from contextvars import ContextVar

from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import PermissionDenied

from apps.core.errors import Conflict
from apps.core.permissions import can_manage_quiz
from apps.quiz.models import Quiz, QuizVersion
from apps.quiz.services import (
    _quiz_content_write,
    lock_relevant_versions,
    version_data,
    versions_have_equal_content,
)
from apps.quiz.validation import validate_quiz_data
from apps.session.models import LiveSession


_SESSION_CREATION_DEPTH = ContextVar('session_creation_depth', default=0)


def _live_session_creation_allowed() -> bool:
    return _SESSION_CREATION_DEPTH.get() > 0


@contextmanager
def _live_session_creation():
    token = _SESSION_CREATION_DEPTH.set(_SESSION_CREATION_DEPTH.get() + 1)
    try:
        yield
    finally:
        _SESSION_CREATION_DEPTH.reset(token)


@transaction.atomic
def create_live_session(*, quiz_id: int, actor, host_name: str = '') -> LiveSession:
    """Зафиксировать нужную версию и создать сессию одной транзакцией."""
    quiz = Quiz.objects.select_for_update().get(pk=quiz_id)
    if not can_manage_quiz(actor, quiz):
        raise PermissionDenied('Нет прав на запуск этой викторины.')
    if quiz.archived_at is not None:
        raise Conflict('Архивную викторину нельзя запустить.')

    draft, latest_fixed = lock_relevant_versions(quiz)
    if draft is None and latest_fixed is None:
        raise Conflict('У викторины отсутствует версия содержимого.')

    selected = latest_fixed
    if draft is not None and (
        latest_fixed is None or not versions_have_equal_content(draft, latest_fixed)
    ):
        validate_quiz_data(version_data(draft))
        with _quiz_content_write():
            draft.status = QuizVersion.STATUS_FIXED
            draft.fixed_at = timezone.now()
            draft.save(update_fields=['status', 'fixed_at', 'updated_at'])
        selected = draft

    with _live_session_creation():
        session = LiveSession(
            quiz_version=selected,
            created_by=actor,
            host_name=host_name,
        )
        session.save(force_insert=True)
    return session
