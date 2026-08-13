from __future__ import annotations

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ..models import Command, CommandAck
from ..schemas import AckRequest, DeviceCommand


class CommandNotFoundError(Exception):
    pass


class CommandConflictError(Exception):
    pass


def expire_pending_commands(
    session: Session, *, error_code: str = "command_expired"
) -> int:
    """Prevent commands from a previous backend process being replayed."""
    result = session.execute(
        update(Command)
        .where(Command.status == "pending")
        .values(status="expired", error_code=error_code)
    )
    session.commit()
    return int(result.rowcount or 0)


def to_schema(command: Command) -> DeviceCommand:
    return DeviceCommand(
        protocol_version=command.protocol_version,
        command_id=command.command_id,
        target=command.target,
        pattern=command.pattern,
        duration_ms=command.duration_ms,
        expire_at_ms=command.expire_at_ms,
        reason_code=command.reason_code,
    )


def create_command(
    session: Session,
    payload: DeviceCommand,
    created_at_ms: int,
    event_id: str | None = None,
) -> Command:
    existing = session.get(Command, payload.command_id)
    if existing is not None:
        if to_schema(existing) == payload:
            return existing
        raise CommandConflictError("command_id already exists with different content")
    command = Command(
        **payload.model_dump(), created_at_ms=created_at_ms, event_id=event_id
    )
    session.add(command)
    session.commit()
    session.refresh(command)
    return command


def pending_command(session: Session, target: str | None, now_ms: int) -> Command | None:
    session.execute(
        update(Command)
        .where(Command.status == "pending", Command.expire_at_ms <= now_ms)
        .values(status="expired", error_code="command_expired")
    )
    session.commit()
    conditions = [Command.status == "pending", Command.expire_at_ms > now_ms]
    if target in {"left", "right"}:
        conditions.append(Command.target.in_([target, "both"]))
    elif target == "both":
        conditions.append(Command.target == "both")
    return session.scalar(
        select(Command)
        .where(*conditions)
        .order_by(Command.created_at_ms.asc())
        .limit(1)
    )


def apply_ack(session: Session, payload: AckRequest) -> bool:
    command = session.get(Command, payload.command_id)
    if command is None:
        raise CommandNotFoundError("unknown command_id")
    if payload.status == "executed" and payload.executed_at_ms > command.expire_at_ms:
        raise CommandConflictError("command was executed after expire_at_ms")
    existing = session.scalar(
        select(CommandAck).where(
            CommandAck.command_id == payload.command_id,
            CommandAck.device_id == payload.device_id,
        )
    )
    if existing is not None:
        same_ack = all(
            [
                existing.status == payload.status,
                existing.ack_at_ms == payload.ack_at_ms,
                existing.executed_at_ms == payload.executed_at_ms,
                existing.error_code == payload.error_code,
            ]
        )
        if same_ack:
            return False
        raise CommandConflictError("same command_id and device_id has a different ACK")
    session.add(
        CommandAck(
            command_id=payload.command_id,
            device_id=payload.device_id,
            status=payload.status,
            ack_at_ms=payload.ack_at_ms,
            executed_at_ms=payload.executed_at_ms,
            error_code=payload.error_code,
        )
    )
    session.flush()
    acknowledgements = list(
        session.scalars(
            select(CommandAck).where(CommandAck.command_id == payload.command_id)
        )
    )
    expected_count = 2 if command.target == "both" else 1
    if len(acknowledgements) < expected_count:
        # A bilateral command is complete only after both devices report their
        # own final AckEvent. Keep it pending after the first side responds.
        command.status = "pending"
        command.ack_at_ms = None
        command.executed_at_ms = None
        command.error_code = "none"
    else:
        failed = next(
            (ack for ack in acknowledgements if ack.status != "executed"),
            None,
        )
        if failed is None:
            command.status = "executed"
            command.error_code = "none"
            command.executed_at_ms = max(
                ack.executed_at_ms or 0 for ack in acknowledgements
            )
        else:
            command.status = failed.status
            command.error_code = failed.error_code
            command.executed_at_ms = None
        command.ack_at_ms = max(ack.ack_at_ms for ack in acknowledgements)
    session.commit()
    return True
