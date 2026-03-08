import threading
from typing import Dict, Tuple

from django.db import close_old_connections

from apps.session.models import LiveSession
from apps.session.realtime import broadcast_session_event, build_answer_reveal_payload

# In-process timers are enough for MVP single-instance deployment.
_TIMER_LOCK = threading.Lock()
_TIMER_REGISTRY: Dict[int, Tuple[int, threading.Timer]] = {}


def cancel_auto_reveal(session_id: int) -> None:
    with _TIMER_LOCK:
        entry = _TIMER_REGISTRY.pop(session_id, None)
    if entry is not None:
        _, timer = entry
        timer.cancel()


def schedule_auto_reveal(session_id: int, question_id: int, delay_seconds: int) -> None:
    cancel_auto_reveal(session_id)

    safe_delay = max(int(delay_seconds), 1)
    timer = threading.Timer(safe_delay, _auto_reveal_callback, args=(session_id, question_id))
    timer.daemon = True

    with _TIMER_LOCK:
        _TIMER_REGISTRY[session_id] = (question_id, timer)

    timer.start()


def _auto_reveal_callback(session_id: int, question_id: int) -> None:
    try:
        close_old_connections()

        try:
            session = (
                LiveSession.objects.select_related("current_question")
                .prefetch_related("current_question__choices")
                .get(id=session_id)
            )
        except LiveSession.DoesNotExist:
            return

        if session.status != LiveSession.STATUS_LIVE:
            return

        if session.current_question_id != question_id:
            return

        payload = build_answer_reveal_payload(session)
        payload["revealed_by"] = "auto"
        payload["auto"] = True
        broadcast_session_event(session_id, "answer_revealed", payload)
    finally:
        close_old_connections()
        with _TIMER_LOCK:
            existing = _TIMER_REGISTRY.get(session_id)
            if existing is not None and existing[0] == question_id:
                _TIMER_REGISTRY.pop(session_id, None)
