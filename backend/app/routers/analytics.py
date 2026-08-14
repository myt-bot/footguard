from __future__ import annotations

import csv
import io
import json
from math import log, sqrt
from collections import Counter
from time import time

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import (
    CalibrationState,
    Command,
    CommandAck,
    InterventionFeedback,
    RiskEvent,
    SensorFrame,
)
from ..schemas import RiskEventOut, RiskState, SessionAdviceResponse, SessionSummary
from ..services.risk_service import calibration_status
from ..services.session_service import recovery_observation
from ..services.ai_advisor_service import generate_session_advice
from ..repositories.calibration_repository import BASELINE_STATE_KEY

router = APIRouter(prefix="/api/v1", tags=["analytics"])


def _event_out(session: Session, event: RiskEvent) -> RiskEventOut:
    feedback = session.scalar(select(InterventionFeedback).where(InterventionFeedback.event_id == event.event_id).order_by(InterventionFeedback.id.desc()).limit(1))
    try:
        raw_components = json.loads(event.risk_components_json or "[]")
        components = [RiskState.model_validate(item) for item in raw_components]
    except (TypeError, ValueError):
        components = []
    return RiskEventOut(
        event_id=event.event_id, risk_type=event.risk_type, risk_side=event.risk_side,
        risk_level=event.risk_level, started_at_ms=event.started_at_ms,
        ended_at_ms=event.ended_at_ms, duration_ms=event.duration_ms,
        before_load_diff=feedback.before_load_diff if feedback else event.before_load_diff,
        after_load_diff=feedback.after_load_diff if feedback else event.after_load_diff,
        intervention_action=feedback.user_action if feedback else None,
        effect_label=feedback.effect_label if feedback else None,
        recovery_time_ms=feedback.recovery_time_ms if feedback else None,
        status=event.status,
        active_risks=components or [RiskState(risk_type=event.risk_type, risk_side=event.risk_side, risk_level=event.risk_level, duration_ms=event.duration_ms)],
    )


@router.get("/session/latest", response_model=SessionSummary)
def latest_session(session: Session = Depends(get_db)) -> SessionSummary:
    latest_left = session.scalar(select(SensorFrame).where(SensorFrame.side == "left").order_by(SensorFrame.timestamp_ms.desc()).limit(1))
    latest_right = session.scalar(select(SensorFrame).where(SensorFrame.side == "right").order_by(SensorFrame.timestamp_ms.desc()).limit(1))
    latest = max((item for item in (latest_left, latest_right) if item is not None), key=lambda item: item.timestamp_ms, default=None)
    now_ms = int(time() * 1000)
    calibration_state = session.get(CalibrationState, BASELINE_STATE_KEY)
    latest_data_ms = latest.timestamp_ms if latest is not None else now_ms
    window_start_ms = max(
        latest_data_ms - 30 * 60 * 1000,
        calibration_state.reset_at_ms if calibration_state and calibration_state.reset_at_ms else 0,
    )
    events = list(session.scalars(select(RiskEvent).where(RiskEvent.started_at_ms >= window_start_ms).order_by(RiskEvent.started_at_ms.desc())))
    counts = Counter(event.risk_type for event in events)
    longest: dict[str, int] = {}
    for event in events:
        longest[event.risk_type] = max(longest.get(event.risk_type, 0), event.duration_ms)
    event_ids = [event.event_id for event in events]
    commands = list(session.scalars(select(Command).where(Command.event_id.in_(event_ids)))) if event_ids else []
    command_ids = [command.command_id for command in commands]
    ack_count = session.query(CommandAck).filter(CommandAck.command_id.in_(command_ids)).count() if command_ids else 0
    feedbacks = list(session.scalars(select(InterventionFeedback).where(InterventionFeedback.event_id.in_(event_ids)))) if event_ids else []
    recoveries = Counter(
        feedback.effect_label for feedback in feedbacks
    )
    status = "empty" if latest is None else ("live" if now_ms - latest.timestamp_ms < 10_000 else "recent")
    calibration = calibration_status(session)
    left_valid = 0 if latest_left is None else 6 - (latest_left.quality_flags & 0x3F).bit_count()
    right_valid = 0 if latest_right is None else 6 - (latest_right.quality_flags & 0x3F).bit_count()
    temperature_available = any(
        item is not None and item.quality_flags & 0x3C0 != 0x3C0
        for item in (latest_left, latest_right)
    )
    return SessionSummary(
        session_status=status,
        data_source=latest.source if latest else "none",
        last_data_at_ms=latest.timestamp_ms if latest else None,
        baseline_ready=calibration.baseline_ready,
        pressure_available=left_valid >= 4 and right_valid >= 4,
        temperature_available=temperature_available,
        left_device_id=latest_left.device_id if latest_left else None,
        right_device_id=latest_right.device_id if latest_right else None,
        left_valid_pressure_channels=left_valid,
        right_valid_pressure_channels=right_valid,
        event_count=len(events), highest_risk_level=max((event.risk_level for event in events), default=0),
        risk_counts=dict(counts), longest_duration_ms=longest,
        motor_command_count=len(commands),
        motor_executed_count=sum(command.status == "executed" for command in commands),
        motor_ack_count=ack_count,
        recovery_counts=dict(recoveries),
        latest_events=[_event_out(session, event) for event in events[:8]],
    )


@router.post("/ai/session-advice", response_model=SessionAdviceResponse)
def session_advice(session: Session = Depends(get_db)) -> SessionAdviceResponse:
    return generate_session_advice(latest_session(session))


@router.get("/analytics/summary")
def analytics_summary(session: Session = Depends(get_db)) -> dict:
    summary = latest_session(session)
    observation = recovery_observation(session)
    return {"session": summary.model_dump(), "recovery_observation": observation.model_dump() if observation else None}


@router.get("/analytics/timeseries")
def analytics_timeseries(limit: int = 240, session: Session = Depends(get_db)) -> list[dict]:
    rows = list(session.scalars(select(SensorFrame).order_by(SensorFrame.timestamp_ms.desc()).limit(min(limit, 2000))))
    return [
        {"timestamp_ms": row.timestamp_ms, "side": row.side, "total_pressure": sum([row.p1,row.p2,row.p3,row.p4,row.p5,row.p6]), "forefoot_ratio": (row.p1+row.p2+row.p3) / max(sum([row.p1,row.p2,row.p3,row.p4,row.p5,row.p6]), 1e-6), "temperature_mean": sum([row.t1,row.t2,row.t3,row.t4]) / 4, "quality_flags": row.quality_flags}
        for row in reversed(rows)
    ]


@router.get("/export/events.csv")
def export_events(session: Session = Depends(get_db)) -> StreamingResponse:
    output = io.StringIO(); writer = csv.writer(output)
    writer.writerow(["event_id","risk_type","risk_side","risk_level","started_at_ms","ended_at_ms","duration_ms","status","intervention_action","effect_label","recovery_time_ms"])
    for event in session.scalars(select(RiskEvent).order_by(RiskEvent.started_at_ms.desc())):
        item = _event_out(session, event)
        writer.writerow([item.event_id,item.risk_type,item.risk_side,item.risk_level,item.started_at_ms,item.ended_at_ms,item.duration_ms,item.status,item.intervention_action,item.effect_label,item.recovery_time_ms])
    return StreamingResponse(iter([output.getvalue()]), media_type="text/csv; charset=utf-8", headers={"Content-Disposition":"attachment; filename=footguard-events.csv"})


@router.get("/export/session.csv")
def export_session(session: Session = Depends(get_db)) -> StreamingResponse:
    rows = list(session.scalars(select(SensorFrame).order_by(SensorFrame.timestamp_ms.desc()).limit(4000)))
    pairs: dict[tuple[int, int], dict[str, SensorFrame]] = {}
    for row in reversed(rows):
        pairs.setdefault((row.sync_id, row.packet_seq), {})[row.side] = row
    output = io.StringIO(); writer = csv.writer(output)
    writer.writerow([
        "timestamp_ms", "left_total_pressure", "right_total_pressure",
        "log_load_ratio", "left_forefoot_ratio", "right_forefoot_ratio",
        "max_same_region_temperature_delta_c", "motion_state",
        "left_valid_pressure_channels", "right_valid_pressure_channels",
        "risk_type", "risk_side", "risk_level",
    ])
    events = list(session.scalars(select(RiskEvent).order_by(RiskEvent.started_at_ms)))
    for pair in pairs.values():
        left, right = pair.get("left"), pair.get("right")
        if left is None or right is None or abs(left.timestamp_ms - right.timestamp_ms) > 50:
            continue
        left_values = [left.p1, left.p2, left.p3, left.p4, left.p5, left.p6]
        right_values = [right.p1, right.p2, right.p3, right.p4, right.p5, right.p6]
        left_total, right_total = sum(left_values), sum(right_values)
        temperature_delta = max(abs(a - b) for a, b in zip(
            [left.t1, left.t2, left.t3, left.t4],
            [right.t1, right.t2, right.t3, right.t4],
        ))
        gyro = max(abs(value) for value in (left.gx, left.gy, left.gz, right.gx, right.gy, right.gz))
        acceleration_delta = max(
            abs(sqrt(row.ax * row.ax + row.ay * row.ay + row.az * row.az) - 9.80665)
            for row in (left, right)
        )
        timestamp_ms = max(left.timestamp_ms, right.timestamp_ms)
        active_event = next((event for event in events if event.started_at_ms <= timestamp_ms <= (event.ended_at_ms or timestamp_ms)), None)
        writer.writerow([
            timestamp_ms, left_total, right_total,
            log((left_total + 1e-6) / (right_total + 1e-6)),
            sum(left_values[:4]) / max(left_total, 1e-6),
            sum(right_values[:4]) / max(right_total, 1e-6),
            temperature_delta,
            "moving" if gyro > 12.0 or acceleration_delta > 3.0 else "stationary",
            6 - (left.quality_flags & 0x3F).bit_count(),
            6 - (right.quality_flags & 0x3F).bit_count(),
            active_event.risk_type if active_event else "normal",
            active_event.risk_side if active_event else "none",
            active_event.risk_level if active_event else 0,
        ])
    return StreamingResponse(iter([output.getvalue()]), media_type="text/csv; charset=utf-8", headers={"Content-Disposition":"attachment; filename=footguard-session.csv"})
