from __future__ import annotations

from dataclasses import dataclass
from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import (
    ATTENTION_AFTER_MS,
    CONTINUITY_GAP_MS,
    FOREFOOT_RATIO_THRESHOLD,
    LOAD_BIAS_ENTER_THRESHOLD,
    PAIRING_BLOCK_FLAGS,
    PAIRING_WINDOW_MS,
    PERSISTENT_AFTER_MS,
    RECOVERY_EFFECTIVE_RATIO,
    RECOVERY_OBSERVATION_MS,
    RECOVERY_PARTIAL_RATIO,
    WARNING_AFTER_MS,
)
from ..models import Command, InterventionFeedback, RiskEvent, SensorFrame
from ..repositories.event_repository import active_event, feedback_for_event
from ..repositories.sensor_repository import latest_frame, recent_frames, to_schema
from ..schemas import RealtimeResponse, RiskState
from .command_service import ensure_motor_command


@dataclass(frozen=True)
class PairMetric:
    sync_id: int
    packet_seq: int
    timestamp_ms: int
    load_bias: float
    load_diff: float
    left_forefoot_ratio: float
    right_forefoot_ratio: float


def _valid_pair(left: SensorFrame, right: SensorFrame) -> bool:
    return (
        left.protocol_version == right.protocol_version == 1
        and left.sync_id != 0
        and left.sync_id == right.sync_id
        and abs(left.timestamp_ms - right.timestamp_ms) <= PAIRING_WINDOW_MS
        and not ((left.quality_flags | right.quality_flags) & PAIRING_BLOCK_FLAGS)
    )


def _metric(left: SensorFrame, right: SensorFrame) -> PairMetric:
    left_values = [left.p1, left.p2, left.p3, left.p4, left.p5, left.p6]
    right_values = [right.p1, right.p2, right.p3, right.p4, right.p5, right.p6]
    left_total = sum(left_values)
    right_total = sum(right_values)
    total = max(left_total + right_total, 1e-9)
    bias = (left_total - right_total) / total
    return PairMetric(
        sync_id=left.sync_id,
        packet_seq=left.packet_seq,
        timestamp_ms=max(left.timestamp_ms, right.timestamp_ms),
        load_bias=bias,
        load_diff=abs(bias),
        left_forefoot_ratio=sum(left_values[:3]) / max(left_total, 1e-9),
        right_forefoot_ratio=sum(right_values[:3]) / max(right_total, 1e-9),
    )


def _pair_history(session: Session) -> list[PairMetric]:
    pairs: dict[tuple[int, int], dict[str, SensorFrame]] = {}
    for frame in recent_frames(session):
        pairs.setdefault((frame.sync_id, frame.packet_seq), {})[frame.side] = frame
    metrics = []
    for pair in pairs.values():
        if set(pair) == {"left", "right"} and _valid_pair(pair["left"], pair["right"]):
            metrics.append(_metric(pair["left"], pair["right"]))
    return sorted(metrics, key=lambda item: item.timestamp_ms)


def _signal(metric: PairMetric) -> tuple[str, str] | None:
    if metric.left_forefoot_ratio >= FOREFOOT_RATIO_THRESHOLD:
        return "forefoot_high", "left"
    if metric.right_forefoot_ratio >= FOREFOOT_RATIO_THRESHOLD:
        return "forefoot_high", "right"
    if metric.load_bias >= LOAD_BIAS_ENTER_THRESHOLD:
        return "left_load_bias", "left"
    if metric.load_bias <= -LOAD_BIAS_ENTER_THRESHOLD:
        return "right_load_bias", "right"
    return None


def _current_risk(metrics: list[PairMetric]) -> tuple[RiskState, PairMetric]:
    latest = metrics[-1]
    current_signal = _signal(latest)
    if current_signal is None:
        return RiskState(risk_type="normal", risk_side="none", risk_level=0, duration_ms=0), latest
    start = latest.timestamp_ms
    next_metric = latest
    for metric in reversed(metrics[:-1]):
        if (
            _signal(metric) != current_signal
            or metric.sync_id != latest.sync_id
            or next_metric.packet_seq != metric.packet_seq + 1
            or next_metric.timestamp_ms - metric.timestamp_ms > CONTINUITY_GAP_MS
        ):
            break
        start = metric.timestamp_ms
        next_metric = metric
    duration = latest.timestamp_ms - start
    if duration < ATTENTION_AFTER_MS:
        level = 0
        risk_type, risk_side, duration = "normal", "none", 0
    elif duration < WARNING_AFTER_MS:
        level = 1
        risk_type, risk_side = current_signal
    elif duration < PERSISTENT_AFTER_MS:
        level = 2
        risk_type, risk_side = current_signal
    else:
        level = 3
        risk_type, risk_side = current_signal
    return RiskState(
        risk_type=risk_type,
        risk_side=risk_side,
        risk_level=level,
        duration_ms=duration,
    ), latest


def _recovery_label(before: float, after: float) -> str:
    improvement = (before - after) / max(before, 1e-9)
    if improvement >= RECOVERY_EFFECTIVE_RATIO:
        return "effective"
    if improvement >= RECOVERY_PARTIAL_RATIO:
        return "partial"
    return "ineffective"


def _close_event(
    session: Session, event: RiskEvent, timestamp_ms: int, after_diff: float | None, status: str
) -> None:
    event.ended_at_ms = timestamp_ms
    event.duration_ms = max(0, timestamp_ms - event.started_at_ms)
    event.after_load_diff = after_diff
    event.status = status
    command = session.scalar(
        select(Command).where(Command.event_id == event.event_id).limit(1)
    )
    if (
        status == "resolved"
        and command is not None
        and command.status == "executed"
        and feedback_for_event(session, event.event_id) is None
        and event.before_load_diff is not None
        and after_diff is not None
    ):
        session.add(
            InterventionFeedback(
                event_id=event.event_id,
                user_action="motor_vibration",
                effect_label=_recovery_label(event.before_load_diff, after_diff),
                before_load_diff=event.before_load_diff,
                after_load_diff=after_diff,
                recovery_time_ms=event.duration_ms,
                created_at_ms=int(time() * 1000),
            )
        )
    session.commit()


def _refresh_recovery_feedback(session: Session, metric: PairMetric) -> None:
    event = session.scalar(
        select(RiskEvent)
        .where(RiskEvent.status == "resolved", RiskEvent.ended_at_ms.is_not(None))
        .order_by(RiskEvent.ended_at_ms.desc())
        .limit(1)
    )
    if (
        event is None
        or metric.timestamp_ms - event.ended_at_ms > RECOVERY_OBSERVATION_MS
        or event.before_load_diff is None
    ):
        return
    command = session.scalar(
        select(Command).where(
            Command.event_id == event.event_id, Command.status == "executed"
        )
    )
    if command is None:
        return
    feedback = session.scalar(
        select(InterventionFeedback).where(
            InterventionFeedback.event_id == event.event_id,
            InterventionFeedback.user_action == "motor_vibration",
        )
    )
    label = _recovery_label(event.before_load_diff, metric.load_diff)
    if feedback is None:
        feedback = InterventionFeedback(
            event_id=event.event_id,
            user_action="motor_vibration",
            effect_label=label,
            before_load_diff=event.before_load_diff,
            after_load_diff=metric.load_diff,
            recovery_time_ms=max(0, metric.timestamp_ms - event.started_at_ms),
            created_at_ms=int(time() * 1000),
        )
        session.add(feedback)
    else:
        feedback.effect_label = label
        feedback.after_load_diff = metric.load_diff
        feedback.recovery_time_ms = max(0, metric.timestamp_ms - event.started_at_ms)
    session.commit()


def _record_risk(
    session: Session,
    risk: RiskState,
    metric: PairMetric | None,
    *,
    allow_motor_command: bool,
) -> None:
    event = active_event(session)
    if risk.risk_type in {"normal", "data_incomplete"}:
        if event is not None:
            timestamp = metric.timestamp_ms if metric else event.started_at_ms + event.duration_ms
            _close_event(
                session,
                event,
                timestamp,
                metric.load_diff if metric else None,
                "resolved" if risk.risk_type == "normal" else "interrupted",
            )
        if risk.risk_type == "normal" and metric is not None:
            _refresh_recovery_feedback(session, metric)
        return
    if metric is None:
        return
    if event is not None and (
        event.risk_type != risk.risk_type or event.risk_side != risk.risk_side
    ):
        _close_event(session, event, metric.timestamp_ms, metric.load_diff, "resolved")
        event = None
    if event is None:
        event = RiskEvent(
            event_id=f"evt_{metric.timestamp_ms}_{risk.risk_side}",
            risk_type=risk.risk_type,
            risk_side=risk.risk_side,
            risk_level=risk.risk_level,
            started_at_ms=metric.timestamp_ms - risk.duration_ms,
            ended_at_ms=None,
            duration_ms=risk.duration_ms,
            before_load_diff=metric.load_diff,
            after_load_diff=None,
            status="active",
        )
        session.add(event)
    else:
        event.risk_level = risk.risk_level
        event.duration_ms = risk.duration_ms
        event.after_load_diff = metric.load_diff
    session.commit()
    if allow_motor_command:
        ensure_motor_command(session, event, risk.risk_level)


def evaluate_risk(
    session: Session,
    *,
    record: bool = False,
    allow_motor_command: bool = True,
) -> RealtimeResponse:
    left_model = latest_frame(session, "left")
    right_model = latest_frame(session, "right")
    left = to_schema(left_model) if left_model else None
    right = to_schema(right_model) if right_model else None
    latest_pair_valid = (
        left_model is not None
        and right_model is not None
        and left_model.packet_seq == right_model.packet_seq
        and _valid_pair(left_model, right_model)
    )
    if not latest_pair_valid:
        risk = RiskState(
            risk_type="data_incomplete", risk_side="none", risk_level=0, duration_ms=0
        )
        if record:
            _record_risk(
                session, risk, None, allow_motor_command=allow_motor_command
            )
        return RealtimeResponse(
            left=left, right=right, paired_timestamp_ms=None, sync_error_ms=None,
            load_bias=None, load_diff=None, risk=risk
        )
    metrics = _pair_history(session)
    risk, metric = _current_risk(metrics)
    if record:
        _record_risk(
            session, risk, metric, allow_motor_command=allow_motor_command
        )
    return RealtimeResponse(
        left=left,
        right=right,
        paired_timestamp_ms=metric.timestamp_ms,
        sync_error_ms=abs(left.timestamp_ms - right.timestamp_ms),
        load_bias=metric.load_bias,
        load_diff=metric.load_diff,
        risk=risk,
    )
