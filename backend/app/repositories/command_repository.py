from __future__ import annotations

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ..models import Command, CommandAck
from ..schemas import AckRequest, DeviceCommand


class CommandNotFoundError(Exception):
    pass


class CommandConflictError(Exception):
    pass


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
    command.status = payload.status
    command.ack_at_ms = payload.ack_at_ms
    command.executed_at_ms = payload.executed_at_ms
    command.error_code = payload.error_code
    session.commit()
    return True
