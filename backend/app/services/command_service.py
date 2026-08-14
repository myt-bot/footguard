from __future__ import annotations

from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import (
    MOTOR_COMMAND_LEVEL,
    MOTOR_COMMAND_TTL_MS,
    MOTOR_PERSISTENT_DURATION_MS,
    MOTOR_PERSISTENT_PATTERN,
)
from ..models import Command, RiskEvent
from ..repositories.command_repository import create_command
from ..schemas import DeviceCommand, RiskState


def motor_profile_for_level(risk_level: int) -> tuple[str, int] | None:
    """Map a rule-engine risk level to a deterministic motor pattern."""
    if risk_level < MOTOR_COMMAND_LEVEL:
        return None
    return MOTOR_PERSISTENT_PATTERN, MOTOR_PERSISTENT_DURATION_MS


def ensure_motor_command(
    session: Session, event: RiskEvent, risk_level: int
) -> Command | None:
    """Create one persistent-level motor command at most per risk event."""
    profile = motor_profile_for_level(risk_level)
    if profile is None or event.risk_side not in {"left", "right"}:
        return None
    pattern, duration_ms = profile
    existing = session.scalar(
        select(Command).where(Command.event_id == event.event_id).limit(1)
    )
    if existing is not None:
        return existing

    now_ms = int(time() * 1000)
    compact_event_id = event.event_id.removeprefix("evt_")
    suffix = "_l3"
    command_id = f"cmd_{compact_event_id}"
    command_id = f"{command_id[: 52 - len(suffix)]}{suffix}"
    command = DeviceCommand(
        command_id=command_id,
        target=event.risk_side,
        pattern=pattern,
        duration_ms=duration_ms,
        expire_at_ms=now_ms + MOTOR_COMMAND_TTL_MS,
        reason_code=event.risk_type,
    )
    return create_command(session, command, now_ms, event_id=event.event_id)


def ensure_combined_motor_command(
    session: Session,
    event: RiskEvent,
    risks: list[RiskState],
) -> Command | None:
    actionable = [risk for risk in risks if risk.risk_level >= MOTOR_COMMAND_LEVEL]
    if not actionable:
        return None
    existing_for_event = session.scalar(
        select(Command).where(Command.event_id == event.event_id).limit(1)
    )
    if existing_for_event is not None:
        return existing_for_event
    sides = {
        side
        for risk in actionable
        for side in (
            ("left", "right")
            if risk.risk_side == "both"
            else (risk.risk_side,)
            if risk.risk_side in {"left", "right"}
            else ()
        )
    }
    if not sides:
        return None
    target = "both" if sides == {"left", "right"} else next(iter(sides))
    primary = sorted(
        actionable,
        key=lambda risk: (-risk.risk_level, -risk.duration_ms),
    )[0]
    pattern = MOTOR_PERSISTENT_PATTERN
    duration_ms = MOTOR_PERSISTENT_DURATION_MS
    reason_code = primary.risk_type
    now_ms = int(time() * 1000)
    suffix = f"_{pattern}_{target[0]}"
    base = f"cmd_{event.event_id.removeprefix('evt_')}"
    command = DeviceCommand(
        command_id=f"{base[: 52 - len(suffix)]}{suffix}",
        target=target,
        pattern=pattern,
        duration_ms=duration_ms,
        expire_at_ms=now_ms + MOTOR_COMMAND_TTL_MS,
        reason_code=reason_code,
    )
    return create_command(session, command, now_ms, event_id=event.event_id)
