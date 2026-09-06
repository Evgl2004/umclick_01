from __future__ import annotations

from celery import shared_task
from apps.session.advance import advance_session_if_due
from apps.session.models import LiveSession


@shared_task(name="apps.session.auto_reveal_due_sessions")
def auto_reveal_due_sessions() -> int:
    """Продвинуть на один переход каждую сессию с истёкшим сроком."""
    advanced_count = 0

    sessions = (
        LiveSession.objects.select_related(
            "quiz_version", "quiz_version__quiz", "current_question"
        )
        .filter(
            status=LiveSession.STATUS_LIVE,
        )
    )

    for session in sessions.iterator():
        _, advanced = advance_session_if_due(session)
        if advanced:
            advanced_count += 1

    return advanced_count
