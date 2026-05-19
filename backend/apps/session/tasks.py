from __future__ import annotations

from celery import shared_task
from django.utils import timezone

from apps.session.autoreveal import reveal_current_question_once
from apps.session.flow import start_answering_for_current_question, start_reading_for_next_question
from apps.session.models import LiveSession
from apps.session.realtime import compute_phase_ends_at, compute_question_ends_at


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
        question = session.current_question
        if session.phase == LiveSession.PHASE_READING:
            reading_ends_at = compute_phase_ends_at(session)
            if reading_ends_at is not None and now >= reading_ends_at:
                if start_answering_for_current_question(session) is not None:
                    revealed_count += 1
            continue

        if session.phase == LiveSession.PHASE_RESULTS:
            results_ends_at = compute_phase_ends_at(session)
            if results_ends_at is not None and now >= results_ends_at:
                start_reading_for_next_question(session)
                revealed_count += 1
            continue

        if session.phase != LiveSession.PHASE_ANSWERING:
            continue
        if question is None or session.question_started_at is None:
            continue
        if session.revealed_question_id == session.current_question_id:
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
