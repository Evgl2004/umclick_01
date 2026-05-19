from __future__ import annotations

from django.db import transaction
from django.utils import timezone

from apps.session.models import LiveSession
from apps.session.realtime import broadcast_session_event, build_answer_reveal_payload


def cancel_auto_reveal(session_id: int) -> None:
    """Compatibility no-op for Celery beat based timer mode."""
    return None


def schedule_auto_reveal(session_id: int, question_id: int, delay_seconds: int) -> None:
    """Compatibility no-op for Celery beat based timer mode."""
    return None


def reveal_current_question_once(
    session_id: int,
    *,
    expected_question_id: int | None,
    revealed_by: str,
    auto: bool,
) -> dict | None:
    """Atomically reveal answers only once for the active session question."""
    with transaction.atomic():
        try:
            session = LiveSession.objects.select_for_update().get(id=session_id)
        except LiveSession.DoesNotExist:
            return None

        if session.status != LiveSession.STATUS_LIVE:
            return None
        if session.current_question_id is None:
            return None
        if expected_question_id is not None and session.current_question_id != expected_question_id:
            return None
        if session.revealed_question_id == session.current_question_id:
            return None

        session.revealed_question_id = session.current_question_id
        session.phase = LiveSession.PHASE_RESULTS
        session.phase_started_at = timezone.now()
        session.save(update_fields=["revealed_question_id", "phase", "phase_started_at"])

        payload = build_answer_reveal_payload(session)

    payload["revealed_by"] = revealed_by
    payload["auto"] = auto
    broadcast_session_event(session_id, "answer_revealed", payload)
    return payload
