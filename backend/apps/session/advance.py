from __future__ import annotations

from apps.session.gameplay import advance_one_transition
from apps.session.models import LiveSession


def advance_session_if_due(
    session: LiveSession,
    *,
    now=None,
) -> tuple[LiveSession, bool]:
    """Восстановить одно устойчивое состояние через общую машину переходов."""
    return advance_one_transition(session.pk, now=now)
