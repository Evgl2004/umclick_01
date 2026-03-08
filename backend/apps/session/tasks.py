from __future__ import annotations

from celery import shared_task
from django.db.models import F
from django.utils import timezone

from apps.session.autoreveal import reveal_current_question_once
from apps.session.models import LiveSession
from apps.session.realtime import compute_question_ends_at


@shared_task(name="apps.session.auto_reveal_due_sessions")
def auto_reveal_due_sessions() -> int:
    """Reveal answers for all due live questions. Runs from Celery beat."""
    now = timezone.now()
    revealed_count = 0

    sessions = (
        LiveSession.objects.select_related("current_question")
        .filter(
            status=LiveSession.STATUS_LIVE,
            current_question__isnull=False,
            question_started_at__isnull=False,
        )
        .exclude(revealed_question_id=F("current_question_id"))
    )

    for session in sessions.iterator():
        question = session.current_question
        if question is None:
            continue

        ends_at = compute_question_ends_at(session, question)
        if ends_at is None or now < ends_at:
            continue

        payload = reveal_current_question_once(
            session.id,
            expected_question_id=question.id,
            revealed_by="auto",
            auto=True,
        )
        if payload is not None:
            revealed_count += 1

    return revealed_count
