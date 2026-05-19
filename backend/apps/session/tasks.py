from __future__ import annotations

from celery import shared_task
from django.utils import timezone

from apps.session.advance import advance_session_if_due
from apps.session.models import LiveSession


@shared_task(name="apps.session.auto_reveal_due_sessions")
def auto_reveal_due_sessions() -> int:
    """Reveal answers for all due live questions. Runs from Celery beat."""
    now = timezone.now()
    revealed_count = 0

    sessions = (
        LiveSession.objects.select_related("quiz", "current_question")
        .filter(
            status=LiveSession.STATUS_LIVE,
        )
    )

    for session in sessions.iterator():
        _, advanced = advance_session_if_due(session, now=now)
        if advanced:
            revealed_count += 1

    return revealed_count
