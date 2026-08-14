from __future__ import annotations

import json
from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import RECOVERY_OBSERVATION_MS
from ..models import Command, RiskEvent
from ..repositories.calibration_repository import calibration_state
from ..schemas import RecoveryObservation, RiskState
from .session_metrics import component_feedback


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
    effect_label = None
    components = []
    try:
        raw_components = json.loads(event.risk_components_json or "[]")
        components = [RiskState.model_validate(item) for item in raw_components]
    except (TypeError, ValueError):
        components = []
    components = components or [
        RiskState(
            risk_type=event.risk_type,
            risk_side=event.risk_side,
            risk_level=event.risk_level,
            duration_ms=event.duration_ms,
        )
    ]
    component_results = []
    if now_ms >= deadline_at_ms:
        component_results = component_feedback(session, components, started_at_ms)
        pressure_results = [
            item.effect_label
            for item in component_results
            if item.pressure_intervention
        ]
        if not pressure_results or "unknown" in pressure_results:
            effect_label = "unknown"
        elif all(item == "effective" for item in pressure_results):
            effect_label = "effective"
        elif all(item == "ineffective" for item in pressure_results):
            effect_label = "ineffective"
        else:
            effect_label = "partial"

    return RecoveryObservation(
        event_id=event.event_id,
        status="observing" if now_ms < deadline_at_ms else "completed",
        started_at_ms=started_at_ms,
        deadline_at_ms=deadline_at_ms,
        remaining_ms=max(0, deadline_at_ms - now_ms),
        effect_label=effect_label,
        component_feedback=component_results,
    )
