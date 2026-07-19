from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import SensorFrame
from ..schemas import FootFrame, ImuData


def _to_model(frame: FootFrame) -> SensorFrame:
    return SensorFrame(
        protocol_version=frame.protocol_version,
        sensor_layout_version=frame.sensor_layout_version,
        device_id=frame.device_id,
        side=frame.side,
        sync_id=frame.sync_id,
        packet_seq=frame.packet_seq,
        timestamp_ms=frame.timestamp_ms,
        p1=frame.pressure[0], p2=frame.pressure[1], p3=frame.pressure[2],
        p4=frame.pressure[3], p5=frame.pressure[4], p6=frame.pressure[5],
        t1=frame.temperature[0], t2=frame.temperature[1],
        t3=frame.temperature[2], t4=frame.temperature[3],
        ax=frame.imu.ax, ay=frame.imu.ay, az=frame.imu.az,
        gx=frame.imu.gx, gy=frame.imu.gy, gz=frame.imu.gz,
        battery=frame.battery,
        quality_flags=frame.quality_flags,
        source=frame.source,
    )


def to_schema(frame: SensorFrame) -> FootFrame:
    return FootFrame(
        protocol_version=frame.protocol_version,
        sensor_layout_version=frame.sensor_layout_version,
        device_id=frame.device_id,
        side=frame.side,
        sync_id=frame.sync_id,
        packet_seq=frame.packet_seq,
        timestamp_ms=frame.timestamp_ms,
        pressure=[frame.p1, frame.p2, frame.p3, frame.p4, frame.p5, frame.p6],
        temperature=[frame.t1, frame.t2, frame.t3, frame.t4],
        imu=ImuData(ax=frame.ax, ay=frame.ay, az=frame.az, gx=frame.gx, gy=frame.gy, gz=frame.gz),
        battery=frame.battery,
        quality_flags=frame.quality_flags,
        source=frame.source,
    )


def add_frames(session: Session, frames: list[FootFrame]) -> tuple[int, int]:
    accepted = 0
    rejected = 0
    for frame in frames:
        duplicate = session.scalar(
            select(SensorFrame.id).where(
                SensorFrame.device_id == frame.device_id,
                SensorFrame.sync_id == frame.sync_id,
                SensorFrame.packet_seq == frame.packet_seq,
            )
        )
        if duplicate is not None:
            rejected += 1
            continue
        session.add(_to_model(frame))
        accepted += 1
    session.commit()
    return accepted, rejected


def latest_frame(session: Session, side: str) -> SensorFrame | None:
    return session.scalar(
        select(SensorFrame)
        .where(SensorFrame.side == side)
        .order_by(SensorFrame.timestamp_ms.desc(), SensorFrame.id.desc())
        .limit(1)
    )


def recent_frames(session: Session, limit: int = 2_000) -> list[SensorFrame]:
    descending = list(
        session.scalars(
            select(SensorFrame)
            .order_by(SensorFrame.timestamp_ms.desc(), SensorFrame.id.desc())
            .limit(limit)
        )
    )
    return list(reversed(descending))
