from __future__ import annotations

from django.utils import timezone

from apps.session.autoreveal import reveal_current_question_once
from apps.session.flow import start_answering_for_current_question, start_reading_for_next_question
from apps.session.models import LiveSession
from apps.session.realtime import compute_phase_ends_at, compute_question_ends_at


def advance_session_if_due(
    session: LiveSession,
    *,
    now=None,
) -> tuple[LiveSession, bool]:
    """Продвинуть истёкшую фазу; опрос состояния дополняет основной таймер Celery beat."""
    if session.status != LiveSession.STATUS_LIVE:
        return session, False

    now = now or timezone.now()
    advanced = False

    if session.phase == LiveSession.PHASE_READING:
        phase_ends_at = compute_phase_ends_at(session)
        if phase_ends_at is not None and now >= phase_ends_at:
            advanced = start_answering_for_current_question(session) is not None

    elif session.phase == LiveSession.PHASE_RESULTS:
        phase_ends_at = compute_phase_ends_at(session)
        if phase_ends_at is not None and now >= phase_ends_at:
            start_reading_for_next_question(session)
            advanced = True

    elif session.phase == LiveSession.PHASE_ANSWERING:
        question = session.current_question
        question_ends_at = compute_question_ends_at(session, question)
        if (
            question is not None
            and question_ends_at is not None
            and now >= question_ends_at
            and session.revealed_question_id != session.current_question_id
        ):
            advanced = (
                reveal_current_question_once(
                    session.id,
                    expected_question_id=question.id,
                    revealed_by="auto",
                    auto=True,
                )
                is not None
            )

    if advanced:
        session.refresh_from_db()

    return session, advanced
