from __future__ import annotations

from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import (
    MOTOR_COMMAND_LEVEL,
    MOTOR_COMMAND_TTL_MS,
    MOTOR_DURATION_MS,
    MOTOR_PATTERN,
)
from ..models import Command, RiskEvent
from ..repositories.command_repository import create_command
from ..schemas import DeviceCommand


def ensure_motor_command(
    session: Session, event: RiskEvent, risk_level: int
) -> Command | None:
    """Create at most one motor vibration command for one risk event."""
    if risk_level < MOTOR_COMMAND_LEVEL or event.risk_side not in {"left", "right"}:
        return None
    existing = session.scalar(
        select(Command).where(Command.event_id == event.event_id).limit(1)
    )
    if existing is not None:
        return existing

    now_ms = int(time() * 1000)
    compact_event_id = event.event_id.removeprefix("evt_")
    command = DeviceCommand(
        command_id=f"cmd_{compact_event_id}",
        target=event.risk_side,
        pattern=MOTOR_PATTERN,
        duration_ms=MOTOR_DURATION_MS,
        expire_at_ms=now_ms + MOTOR_COMMAND_TTL_MS,
        reason_code=event.risk_type,
    )
    return create_command(session, command, now_ms, event_id=event.event_id)
