from __future__ import annotations

from dataclasses import dataclass
from statistics import median
from time import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import (
    ATTENTION_AFTER_MS,
    BASELINE_BALANCED_BIAS_MAX,
    BASELINE_MIN_SAMPLES,
    CONTINUITY_GAP_MS,
    DEFAULT_PRESSURE_DISTRIBUTION,
    FOREFOOT_RATIO_DELTA_THRESHOLD,
    LOAD_BIAS_ENTER_THRESHOLD,
    PAIRING_BLOCK_FLAGS,
    PAIRING_WINDOW_MS,
    PERSISTENT_AFTER_MS,
    RECOVERY_EFFECTIVE_RATIO,
    RECOVERY_OBSERVATION_MS,
    RECOVERY_PARTIAL_RATIO,
    REGIONAL_ASYMMETRY_FOR_SEVERE,
    REGIONAL_SHARE_DELTA_FOR_SEVERE,
    TEMPERATURE_DELTA_C_THRESHOLD,
    WARNING_AFTER_MS,
)
from ..models import Command, InterventionFeedback, RiskEvent, SensorFrame
from ..repositories.event_repository import active_event, feedback_for_event
from ..repositories.sensor_repository import latest_frame, recent_frames, to_schema
from ..schemas import RegionalAnalysis, RealtimeResponse, RiskState
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
    left_pressure: tuple[float, ...]
    right_pressure: tuple[float, ...]
    left_distribution: tuple[float, ...]
    right_distribution: tuple[float, ...]
    temperature_delta_c: tuple[float, ...]


@dataclass(frozen=True)
class BaselineProfile:
    ready: bool
    load_bias: float
    left_distribution: tuple[float, ...]
    right_distribution: tuple[float, ...]
    pressure_asymmetry: tuple[float, ...]
    temperature_delta_c: tuple[float, ...]


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
    left_temperature = [left.t1, left.t2, left.t3, left.t4]
    right_temperature = [right.t1, right.t2, right.t3, right.t4]
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
        left_forefoot_ratio=sum(left_values[:4]) / max(left_total, 1e-9),
        right_forefoot_ratio=sum(right_values[:4]) / max(right_total, 1e-9),
        left_pressure=tuple(left_values),
        right_pressure=tuple(right_values),
        left_distribution=tuple(value / max(left_total, 1e-9) for value in left_values),
        right_distribution=tuple(value / max(right_total, 1e-9) for value in right_values),
        temperature_delta_c=tuple(
            left_value - right_value
            for left_value, right_value in zip(
                left_temperature, right_temperature, strict=True
            )
        ),
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


def _channel_asymmetry(metric: PairMetric, index: int) -> float:
    left = metric.left_pressure[index]
    right = metric.right_pressure[index]
    return (left - right) / max(left + right, 1e-9)


def _median_channels(
    metrics: list[PairMetric], field: str, channel_count: int
) -> tuple[float, ...]:
    return tuple(
        median(getattr(metric, field)[index] for metric in metrics)
        for index in range(channel_count)
    )


def _baseline_profile(metrics: list[PairMetric]) -> BaselineProfile:
    candidates = [
        metric
        for metric in metrics
        if abs(metric.load_bias) <= BASELINE_BALANCED_BIAS_MAX
        and max(abs(value) for value in metric.temperature_delta_c) < 1.0
        and max(
            abs(value - DEFAULT_PRESSURE_DISTRIBUTION[index])
            for index, value in enumerate(metric.left_distribution)
        ) < 0.08
        and max(
            abs(value - DEFAULT_PRESSURE_DISTRIBUTION[index])
            for index, value in enumerate(metric.right_distribution)
        ) < 0.08
    ]
    ready = len(candidates) >= BASELINE_MIN_SAMPLES
    if not ready:
        return BaselineProfile(
            ready=False,
            load_bias=0.0,
            left_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
            right_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
            pressure_asymmetry=(0.0,) * 6,
            temperature_delta_c=(0.0,) * 4,
        )
    return BaselineProfile(
        ready=True,
        load_bias=median(metric.load_bias for metric in candidates),
        left_distribution=_median_channels(candidates, "left_distribution", 6),
        right_distribution=_median_channels(candidates, "right_distribution", 6),
        pressure_asymmetry=tuple(
            median(_channel_asymmetry(metric, index) for metric in candidates)
            for index in range(6)
        ),
        temperature_delta_c=_median_channels(
            candidates, "temperature_delta_c", 4
        ),
    )


def _signal(
    metric: PairMetric, baseline: BaselineProfile
) -> tuple[str, str] | None:
    corrected_temperature = [
        value - baseline.temperature_delta_c[index]
        for index, value in enumerate(metric.temperature_delta_c)
    ]
    hottest = max(corrected_temperature, key=abs)
    if abs(hottest) >= TEMPERATURE_DELTA_C_THRESHOLD:
        return "temperature_asymmetry", "left" if hottest > 0 else "right"

    left_forefoot_baseline = sum(baseline.left_distribution[:4])
    right_forefoot_baseline = sum(baseline.right_distribution[:4])
    if (
        metric.left_forefoot_ratio - left_forefoot_baseline
        >= FOREFOOT_RATIO_DELTA_THRESHOLD
    ):
        return "forefoot_high", "left"
    if (
        metric.right_forefoot_ratio - right_forefoot_baseline
        >= FOREFOOT_RATIO_DELTA_THRESHOLD
    ):
        return "forefoot_high", "right"
    adjusted_bias = metric.load_bias - baseline.load_bias
    if adjusted_bias >= LOAD_BIAS_ENTER_THRESHOLD:
        return "left_load_bias", "left"
    if adjusted_bias <= -LOAD_BIAS_ENTER_THRESHOLD:
        return "right_load_bias", "right"
    return None


def _current_risk(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[RiskState, PairMetric]:
    latest = metrics[-1]
    current_signal = _signal(latest, baseline)
    if current_signal is None:
        return RiskState(risk_type="normal", risk_side="none", risk_level=0, duration_ms=0), latest
    start = latest.timestamp_ms
    next_metric = latest
    for metric in reversed(metrics[:-1]):
        if (
            _signal(metric, baseline) != current_signal
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


def _clamp_score(value: float) -> float:
    return round(max(0.0, min(1.0, value)), 4)


def _regional_analysis(
    metric: PairMetric, baseline: BaselineProfile
) -> RegionalAnalysis:
    left_scores: list[float] = []
    right_scores: list[float] = []
    for index in range(6):
        current_asymmetry = _channel_asymmetry(metric, index)
        corrected_asymmetry = (
            current_asymmetry - baseline.pressure_asymmetry[index]
        )
        left_share_change = (
            metric.left_distribution[index] - baseline.left_distribution[index]
        ) / max(baseline.left_distribution[index], 0.05)
        right_share_change = (
            metric.right_distribution[index] - baseline.right_distribution[index]
        ) / max(baseline.right_distribution[index], 0.05)
        left_scores.append(
            _clamp_score(
                max(
                    left_share_change / REGIONAL_SHARE_DELTA_FOR_SEVERE,
                    corrected_asymmetry / REGIONAL_ASYMMETRY_FOR_SEVERE,
                )
            )
        )
        right_scores.append(
            _clamp_score(
                max(
                    right_share_change / REGIONAL_SHARE_DELTA_FOR_SEVERE,
                    -corrected_asymmetry / REGIONAL_ASYMMETRY_FOR_SEVERE,
                )
            )
        )

    corrected_temperature = [
        round(value - baseline.temperature_delta_c[index], 2)
        for index, value in enumerate(metric.temperature_delta_c)
    ]
    return RegionalAnalysis(
        baseline_ready=baseline.ready,
        baseline_source="personal" if baseline.ready else "layout_default",
        left_pressure_scores=left_scores,
        right_pressure_scores=right_scores,
        temperature_delta_c=corrected_temperature,
        left_temperature_scores=[
            _clamp_score(value / TEMPERATURE_DELTA_C_THRESHOLD)
            for value in corrected_temperature
        ],
        right_temperature_scores=[
            _clamp_score(-value / TEMPERATURE_DELTA_C_THRESHOLD)
            for value in corrected_temperature
        ],
    )


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
    candidate_started_at_ms = metric.timestamp_ms - risk.duration_ms
    # A device reconnect/new sync window can start the same risk type after an
    # earlier command has already expired. Do not reuse that stale event;
    # otherwise ensure_motor_command would correctly deduplicate the old event
    # but the new monitoring episode would never receive a motor reminder.
    if (
        event is not None
        and event.risk_type == risk.risk_type
        and event.risk_side == risk.risk_side
        and candidate_started_at_ms
        > event.started_at_ms + CONTINUITY_GAP_MS
    ):
        _close_event(
            session,
            event,
            candidate_started_at_ms,
            event.after_load_diff,
            "interrupted",
        )
        event = None
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
            started_at_ms=candidate_started_at_ms,
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
            load_bias=None, load_diff=None, risk=risk, regional_analysis=None
        )
    metrics = _pair_history(session)
    baseline = _baseline_profile(metrics)
    risk, metric = _current_risk(metrics, baseline)
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
        regional_analysis=_regional_analysis(metric, baseline),
    )
