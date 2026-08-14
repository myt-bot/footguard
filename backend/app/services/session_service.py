from __future__ import annotations

from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import RECOVERY_OBSERVATION_MS
from ..models import Command, InterventionFeedback, RiskEvent
from ..repositories.calibration_repository import calibration_state
from ..schemas import RecoveryObservation


def recovery_observation(
    session: Session,
    now_ms: int | None = None,
) -> RecoveryObservation | None:
    """Return the latest motor intervention's server-timed observation window."""
    now_ms = now_ms or int(time() * 1000)
    wearing = calibration_state(session)
    reset_at_ms = wearing.reset_at_ms if wearing and wearing.reset_at_ms else 0
    command = session.scalar(
        select(Command)
        .where(
            Command.event_id.is_not(None),
            Command.status == "executed",
            Command.created_at_ms >= reset_at_ms,
        )
        .order_by(Command.executed_at_ms.desc(), Command.created_at_ms.desc())
        .limit(1)
    )
    if command is None or command.event_id is None:
        return None

    event = session.get(RiskEvent, command.event_id)
    if event is None:
        return None

    started_at_ms = command.executed_at_ms or command.ack_at_ms or command.created_at_ms
    deadline_at_ms = started_at_ms + RECOVERY_OBSERVATION_MS
    feedback = session.scalar(
        select(InterventionFeedback)
        .where(InterventionFeedback.event_id == event.event_id)
        .order_by(InterventionFeedback.id.desc())
        .limit(1)
    )
    effect_label = None
    if now_ms >= deadline_at_ms:
        if feedback is not None:
            effect_label = feedback.effect_label
        elif event.status == "active":
            effect_label = "ineffective"
        else:
            effect_label = "unknown"

    return RecoveryObservation(
        event_id=event.event_id,
        status="observing" if now_ms < deadline_at_ms else "completed",
        started_at_ms=started_at_ms,
        deadline_at_ms=deadline_at_ms,
        remaining_ms=max(0, deadline_at_ms - now_ms),
        effect_label=effect_label,
    )
