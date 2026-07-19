from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, Integer, String, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class SensorFrame(Base):
    __tablename__ = "sensor_frames"
    __table_args__ = (UniqueConstraint("device_id", "sync_id", "packet_seq"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    protocol_version: Mapped[int] = mapped_column(Integer)
    sensor_layout_version: Mapped[str] = mapped_column(String(32))
    device_id: Mapped[str] = mapped_column(String(16), index=True)
    side: Mapped[str] = mapped_column(String(5), index=True)
    sync_id: Mapped[int] = mapped_column(Integer)
    packet_seq: Mapped[int] = mapped_column(Integer)
    timestamp_ms: Mapped[int] = mapped_column(Integer, index=True)
    p1: Mapped[float] = mapped_column(Float)
    p2: Mapped[float] = mapped_column(Float)
    p3: Mapped[float] = mapped_column(Float)
    p4: Mapped[float] = mapped_column(Float)
    p5: Mapped[float] = mapped_column(Float)
    p6: Mapped[float] = mapped_column(Float)
    t1: Mapped[float] = mapped_column(Float)
    t2: Mapped[float] = mapped_column(Float)
    t3: Mapped[float] = mapped_column(Float)
    ax: Mapped[float] = mapped_column(Float)
    ay: Mapped[float] = mapped_column(Float)
    az: Mapped[float] = mapped_column(Float)
    gx: Mapped[float] = mapped_column(Float)
    gy: Mapped[float] = mapped_column(Float)
    gz: Mapped[float] = mapped_column(Float)
    battery: Mapped[int] = mapped_column(Integer)
    quality_flags: Mapped[int] = mapped_column(Integer)
    source: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class RiskEvent(Base):
    __tablename__ = "risk_events"

    event_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    risk_type: Mapped[str] = mapped_column(String(32), index=True)
    risk_side: Mapped[str] = mapped_column(String(5))
    risk_level: Mapped[int] = mapped_column(Integer)
    started_at_ms: Mapped[int] = mapped_column(Integer)
    ended_at_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    before_load_diff: Mapped[float | None] = mapped_column(Float, nullable=True)
    after_load_diff: Mapped[float | None] = mapped_column(Float, nullable=True)
    status: Mapped[str] = mapped_column(String(16), default="active")


class Command(Base):
    __tablename__ = "commands"

    command_id: Mapped[str] = mapped_column(String(52), primary_key=True)
    protocol_version: Mapped[int] = mapped_column(Integer, default=1)
    target: Mapped[str] = mapped_column(String(5), index=True)
    pattern: Mapped[str] = mapped_column(String(8))
    duration_ms: Mapped[int] = mapped_column(Integer)
    expire_at_ms: Mapped[int] = mapped_column(Integer, index=True)
    reason_code: Mapped[str] = mapped_column(String(32))
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    created_at_ms: Mapped[int] = mapped_column(Integer)
    executed_at_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    ack_at_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    error_code: Mapped[str] = mapped_column(String(32), default="none")


class CommandAck(Base):
    __tablename__ = "command_acks"
    __table_args__ = (UniqueConstraint("command_id", "device_id"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    command_id: Mapped[str] = mapped_column(String(52), index=True)
    device_id: Mapped[str] = mapped_column(String(16), index=True)
    status: Mapped[str] = mapped_column(String(16))
    ack_at_ms: Mapped[int] = mapped_column(Integer)
    executed_at_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    error_code: Mapped[str] = mapped_column(String(32))


class InterventionFeedback(Base):
    __tablename__ = "intervention_feedback"

    id: Mapped[int] = mapped_column(primary_key=True)
    event_id: Mapped[str] = mapped_column(String(64), index=True)
    user_action: Mapped[str] = mapped_column(String(64))
    effect_label: Mapped[str] = mapped_column(String(16))
    before_load_diff: Mapped[float] = mapped_column(Float)
    after_load_diff: Mapped[float] = mapped_column(Float)
    recovery_time_ms: Mapped[int] = mapped_column(Integer)
    created_at_ms: Mapped[int] = mapped_column(Integer)
