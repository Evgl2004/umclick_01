from __future__ import annotations

from django.utils import timezone

from apps.session.models import LiveSession
from apps.session.realtime import (
    broadcast_session_event,
    build_public_leaderboard,
    build_public_session_state,
    get_next_question,
)


def complete_session(session: LiveSession) -> dict:
    session.status = LiveSession.STATUS_FINISHED
    session.phase = LiveSession.PHASE_FINAL
    session.current_question = None
    session.revealed_question_id = None
    session.phase_started_at = timezone.now()
    session.question_started_at = None
    session.save(
        update_fields=[
            "status",
            "phase",
            "finished_at",
            "current_question",
            "revealed_question_id",
            "phase_started_at",
            "question_started_at",
        ]
    )

    payload = build_public_session_state(session)
    payload["leaderboard"] = build_public_leaderboard(session)
    broadcast_session_event(session.id, "session_finished", payload)
    return payload


def abort_session(session: LiveSession) -> dict:
    session.status = LiveSession.STATUS_ABORTED
    session.phase = LiveSession.PHASE_FINAL
    session.current_question = None
    session.revealed_question_id = None
    session.phase_started_at = timezone.now()
    session.question_started_at = None
    session.save(
        update_fields=[
            "status",
            "phase",
            "finished_at",
            "current_question",
            "revealed_question_id",
            "phase_started_at",
            "question_started_at",
        ]
    )

    payload = build_public_session_state(session)
    payload["leaderboard"] = build_public_leaderboard(session)
    broadcast_session_event(session.id, "session_finished", payload)
    return payload


def start_reading_for_next_question(session: LiveSession) -> dict:
    next_question = get_next_question(session)
    if next_question is None:
        return complete_session(session)

    session.current_question = next_question
    session.revealed_question_id = None
    session.phase = LiveSession.PHASE_READING
    session.phase_started_at = timezone.now()
    session.question_started_at = None
    session.save(
        update_fields=[
            "current_question",
            "revealed_question_id",
            "phase",
            "phase_started_at",
            "question_started_at",
        ]
    )

    payload = build_public_session_state(session)
    broadcast_session_event(session.id, "question_reading_started", payload)
    return payload


def start_answering_for_current_question(session: LiveSession) -> dict | None:
    if session.status != LiveSession.STATUS_LIVE:
        return None
    if session.current_question_id is None:
        return None
    if session.phase != LiveSession.PHASE_READING:
        return None

    session.phase = LiveSession.PHASE_ANSWERING
    session.phase_started_at = timezone.now()
    session.question_started_at = session.phase_started_at
    session.save(update_fields=["phase", "phase_started_at", "question_started_at"])

    payload = build_public_session_state(session)
    payload["question"] = payload.get("current_question")
    broadcast_session_event(session.id, "question_started", payload)
    return payload
