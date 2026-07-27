from __future__ import annotations

from dataclasses import dataclass
from math import sqrt
from statistics import median
from time import time

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ..config import (
    ATTENTION_AFTER_MS,
    BASELINE_ACTIVE_PRESSURE_FLOOR,
    BASELINE_BALANCED_BIAS_MAX,
    BASELINE_CALIBRATION_WINDOW_SAMPLES,
    BASELINE_DISTRIBUTION_INLIER_TOLERANCE,
    BASELINE_LOAD_BIAS_INLIER_TOLERANCE,
    BASELINE_MAX_TEMPERATURE_DELTA_C,
    BASELINE_MIN_ACTIVE_CHANNELS,
    BASELINE_MIN_FOOT_PRESSURE,
    BASELINE_MIN_SAMPLES,
    BASELINE_TEMPERATURE_INLIER_TOLERANCE_C,
    CONTINUITY_GAP_MS,
    DEFAULT_PRESSURE_DISTRIBUTION,
    FOREFOOT_RATIO_DELTA_THRESHOLD,
    FOREFOOT_RATIO_EXIT_THRESHOLD,
    IMU_ACCEL_STATIONARY_TOLERANCE_MS2,
    IMU_GRAVITY_MS2,
    IMU_GYRO_STATIONARY_THRESHOLD_DPS,
    IMU_INVALID_MASK,
    LOAD_BIAS_ENTER_THRESHOLD,
    LOAD_BIAS_EXIT_THRESHOLD,
    PAIRING_BLOCK_FLAGS,
    PAIRING_WINDOW_MS,
    PERSISTENT_AFTER_MS,
    PRESSURE_SMOOTHING_WINDOW_SAMPLES,
    RECOVERY_EFFECTIVE_RATIO,
    RECOVERY_OBSERVATION_MS,
    RECOVERY_PARTIAL_RATIO,
    REGIONAL_ASYMMETRY_FOR_SEVERE,
    REGIONAL_MIN_CHANNEL_EVIDENCE,
    REGIONAL_MIN_VISIBLE_SCORE,
    REGIONAL_SHARE_DELTA_FOR_SEVERE,
    RISK_MIN_TOTAL_PRESSURE,
    TEMPERATURE_DELTA_C_THRESHOLD,
    TEMPERATURE_DELTA_C_EXIT_THRESHOLD,
    WARNING_AFTER_MS,
)
from ..models import Command, InterventionFeedback, RiskEvent, SensorFrame
from ..repositories.calibration_repository import (
    calibration_frame_cutoff,
    calibration_state,
    reset_calibration,
)
from ..repositories.event_repository import active_event, feedback_for_event
from ..repositories.sensor_repository import latest_frame, recent_frames, to_schema
from ..schemas import CalibrationStatus, RegionalAnalysis, RealtimeResponse, RiskState
from .command_service import ensure_motor_command


@dataclass(frozen=True)
class PairMetric:
    sync_id: int
    packet_seq: int
    timestamp_ms: int
    left_total: float
    right_total: float
    load_bias: float
    load_diff: float
    left_forefoot_ratio: float
    right_forefoot_ratio: float
    left_pressure: tuple[float, ...]
    right_pressure: tuple[float, ...]
    left_distribution: tuple[float, ...]
    right_distribution: tuple[float, ...]
    temperature_delta_c: tuple[float, ...]
    motion_state: str = "unavailable"


@dataclass(frozen=True)
class BaselineProfile:
    ready: bool
    sample_count: int
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


def _frame_is_stationary(frame: SensorFrame) -> bool | None:
    if frame.quality_flags & IMU_INVALID_MASK:
        return None
    acceleration = sqrt(frame.ax**2 + frame.ay**2 + frame.az**2)
    angular_speed = sqrt(frame.gx**2 + frame.gy**2 + frame.gz**2)
    # Zero vectors are used by mock/legacy frames and must not be mistaken for
    # a physically stationary MPU under gravity.
    if acceleration < 0.5 and angular_speed < 0.5:
        return None
    return (
        abs(acceleration - IMU_GRAVITY_MS2)
        <= IMU_ACCEL_STATIONARY_TOLERANCE_MS2
        and angular_speed <= IMU_GYRO_STATIONARY_THRESHOLD_DPS
    )


def _motion_state(left: SensorFrame, right: SensorFrame) -> str:
    votes = [
        state
        for state in (_frame_is_stationary(left), _frame_is_stationary(right))
        if state is not None
    ]
    if not votes:
        return "unavailable"
    return "stationary" if all(votes) else "moving"


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
        left_total=left_total,
        right_total=right_total,
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
        motion_state=_motion_state(left, right),
    )


def _pair_history(session: Session) -> list[PairMetric]:
    pairs: dict[tuple[int, int], dict[str, SensorFrame]] = {}
    for frame in recent_frames(
        session,
        after_id=calibration_frame_cutoff(session),
    ):
        pairs.setdefault((frame.sync_id, frame.packet_seq), {})[frame.side] = frame
    metrics = []
    for pair in pairs.values():
        if set(pair) == {"left", "right"} and _valid_pair(pair["left"], pair["right"]):
            metrics.append(_metric(pair["left"], pair["right"]))
    return sorted(metrics, key=lambda item: item.timestamp_ms)


def _latest_complete_pair(
    session: Session,
    left_latest: SensorFrame | None,
    right_latest: SensorFrame | None,
) -> tuple[SensorFrame, SensorFrame] | None:
    """Return the newest valid pair while tolerating one brief side skew.

    Left and right frames are uploaded together, but concurrent realtime reads
    can briefly observe one side from the next packet. Keep the newest complete
    pair only while it is within the normal continuity window; a real one-sided
    disconnect still becomes data_incomplete after that window.
    """
    if (
        left_latest is not None
        and right_latest is not None
        and left_latest.packet_seq == right_latest.packet_seq
        and _valid_pair(left_latest, right_latest)
    ):
        return left_latest, right_latest
    if left_latest is None or right_latest is None:
        return None

    newest_timestamp_ms = max(
        left_latest.timestamp_ms,
        right_latest.timestamp_ms,
    )
    candidates: dict[tuple[int, int], dict[str, SensorFrame]] = {}
    for frame in recent_frames(session, limit=200):
        if frame.side in {"left", "right"}:
            candidates.setdefault(
                (frame.sync_id, frame.packet_seq),
                {},
            )[frame.side] = frame

    newest_pair: tuple[SensorFrame, SensorFrame] | None = None
    newest_pair_timestamp_ms = -1
    for candidate in candidates.values():
        if set(candidate) != {"left", "right"}:
            continue
        left = candidate["left"]
        right = candidate["right"]
        if not _valid_pair(left, right):
            continue
        pair_timestamp_ms = max(left.timestamp_ms, right.timestamp_ms)
        if pair_timestamp_ms > newest_pair_timestamp_ms:
            newest_pair = left, right
            newest_pair_timestamp_ms = pair_timestamp_ms

    if (
        newest_pair is not None
        and newest_timestamp_ms - newest_pair_timestamp_ms
        <= CONTINUITY_GAP_MS
    ):
        return newest_pair
    return None


def _channel_asymmetry(metric: PairMetric, index: int) -> float:
    left = metric.left_pressure[index]
    right = metric.right_pressure[index]
    return (left - right) / max(left + right, 1e-9)


def _pressure_metric_from_window(
    metrics: list[PairMetric], end_index: int | None = None
) -> PairMetric:
    """Return a robust pressure view while preserving current metadata/temperature."""
    if not metrics:
        raise ValueError("pressure smoothing requires at least one metric")
    if end_index is None:
        end_index = len(metrics) - 1
    reference = metrics[end_index]
    start_index = max(0, end_index - PRESSURE_SMOOTHING_WINDOW_SAMPLES + 1)
    window = [
        metric
        for metric in metrics[start_index : end_index + 1]
        if metric.sync_id == reference.sync_id
        and reference.timestamp_ms - metric.timestamp_ms
        <= CONTINUITY_GAP_MS * PRESSURE_SMOOTHING_WINDOW_SAMPLES
    ]
    left_pressure = tuple(
        median(metric.left_pressure[index] for metric in window)
        for index in range(6)
    )
    right_pressure = tuple(
        median(metric.right_pressure[index] for metric in window)
        for index in range(6)
    )
    left_total = sum(left_pressure)
    right_total = sum(right_pressure)
    total = max(left_total + right_total, 1e-9)
    load_bias = (left_total - right_total) / total
    return PairMetric(
        sync_id=reference.sync_id,
        packet_seq=reference.packet_seq,
        timestamp_ms=reference.timestamp_ms,
        left_total=left_total,
        right_total=right_total,
        load_bias=load_bias,
        load_diff=abs(load_bias),
        left_forefoot_ratio=sum(left_pressure[:4]) / max(left_total, 1e-9),
        right_forefoot_ratio=sum(right_pressure[:4]) / max(right_total, 1e-9),
        left_pressure=left_pressure,
        right_pressure=right_pressure,
        left_distribution=tuple(
            value / max(left_total, 1e-9) for value in left_pressure
        ),
        right_distribution=tuple(
            value / max(right_total, 1e-9) for value in right_pressure
        ),
        # Temperature is already slowly varying. Keeping the latest value also
        # keeps the App's displayed left/right values consistent with this delta.
        temperature_delta_c=reference.temperature_delta_c,
        motion_state=reference.motion_state,
    )


def _median_channels(
    metrics: list[PairMetric], field: str, channel_count: int
) -> tuple[float, ...]:
    return tuple(
        median(getattr(metric, field)[index] for metric in metrics)
        for index in range(channel_count)
    )


def _empty_baseline(sample_count: int = 0) -> BaselineProfile:
    return BaselineProfile(
        ready=False,
        sample_count=sample_count,
        load_bias=0.0,
        left_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
        right_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
        pressure_asymmetry=(0.0,) * 6,
        temperature_delta_c=(0.0,) * 4,
    )


def _active_channel_count(values: tuple[float, ...]) -> int:
    return sum(value >= BASELINE_ACTIVE_PRESSURE_FLOOR for value in values)


def _is_baseline_candidate(metric: PairMetric) -> bool:
    return (
        # Do not learn a walking/transient frame as the user's standing
        # reference. Missing MPU data deliberately fails open.
        metric.motion_state != "moving"
        and metric.left_total >= BASELINE_MIN_FOOT_PRESSURE
        and metric.right_total >= BASELINE_MIN_FOOT_PRESSURE
        and _active_channel_count(metric.left_pressure)
        >= BASELINE_MIN_ACTIVE_CHANNELS
        and _active_channel_count(metric.right_pressure)
        >= BASELINE_MIN_ACTIVE_CHANNELS
        and abs(metric.load_bias) <= BASELINE_BALANCED_BIAS_MAX
        and max(abs(value) for value in metric.temperature_delta_c)
        <= BASELINE_MAX_TEMPERATURE_DELTA_C
    )


def _baseline_profile(metrics: list[PairMetric]) -> BaselineProfile:
    # Lock the first stable bilateral-bearing window. Using the newest window
    # would slowly redefine a sustained abnormal posture as the new normal.
    candidates = [
        metric for metric in metrics if _is_baseline_candidate(metric)
    ][:BASELINE_CALIBRATION_WINDOW_SAMPLES]
    if len(candidates) < BASELINE_MIN_SAMPLES:
        return _empty_baseline(len(candidates))

    center_load_bias = median(metric.load_bias for metric in candidates)
    center_left_distribution = _median_channels(
        candidates, "left_distribution", 6
    )
    center_right_distribution = _median_channels(
        candidates, "right_distribution", 6
    )
    center_temperature_delta = _median_channels(
        candidates, "temperature_delta_c", 4
    )
    inliers = [
        metric
        for metric in candidates
        if abs(metric.load_bias - center_load_bias)
        <= BASELINE_LOAD_BIAS_INLIER_TOLERANCE
        and max(
            abs(value - center_left_distribution[index])
            for index, value in enumerate(metric.left_distribution)
        )
        <= BASELINE_DISTRIBUTION_INLIER_TOLERANCE
        and max(
            abs(value - center_right_distribution[index])
            for index, value in enumerate(metric.right_distribution)
        )
        <= BASELINE_DISTRIBUTION_INLIER_TOLERANCE
        and max(
            abs(value - center_temperature_delta[index])
            for index, value in enumerate(metric.temperature_delta_c)
        )
        <= BASELINE_TEMPERATURE_INLIER_TOLERANCE_C
    ]
    if len(inliers) < BASELINE_MIN_SAMPLES:
        return _empty_baseline(len(inliers))

    return BaselineProfile(
        ready=True,
        sample_count=len(inliers),
        load_bias=median(metric.load_bias for metric in inliers),
        left_distribution=_median_channels(inliers, "left_distribution", 6),
        right_distribution=_median_channels(inliers, "right_distribution", 6),
        pressure_asymmetry=tuple(
            median(_channel_asymmetry(metric, index) for metric in inliers)
            for index in range(6)
        ),
        temperature_delta_c=_median_channels(
            inliers, "temperature_delta_c", 4
        ),
    )
def _adjusted_load_bias(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> float:
    return metric.load_bias - baseline.load_bias


def _forefoot_delta(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> float:
    distribution = (
        metric.left_distribution if side == "left" else metric.right_distribution
    )
    baseline_distribution = (
        baseline.left_distribution
        if side == "left"
        else baseline.right_distribution
    )
    return sum(distribution[:4]) - sum(baseline_distribution[:4])


def _temperature_delta_from_baseline(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> tuple[float, float, float, float]:
    return tuple(
        value - baseline.temperature_delta_c[index]
        for index, value in enumerate(metric.temperature_delta_c)
    )


def _signal(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> tuple[str, str] | None:
    if metric.left_total + metric.right_total < RISK_MIN_TOTAL_PRESSURE:
        return None

    # The top-level risk can expose only one condition. Strong left/right
    # imbalance is the most actionable vibration cue, so keep it ahead of
    # regional and temperature observations.
    adjusted_bias = _adjusted_load_bias(metric, baseline)
    if adjusted_bias >= LOAD_BIAS_ENTER_THRESHOLD:
        return "left_load_bias", "left"
    if adjusted_bias <= -LOAD_BIAS_ENTER_THRESHOLD:
        return "right_load_bias", "right"

    if _forefoot_delta(metric, baseline, "left") >= (
        FOREFOOT_RATIO_DELTA_THRESHOLD
    ):
        return "forefoot_high", "left"
    if _forefoot_delta(metric, baseline, "right") >= (
        FOREFOOT_RATIO_DELTA_THRESHOLD
    ):
        return "forefoot_high", "right"

    corrected_temperature = _temperature_delta_from_baseline(metric, baseline)
    hottest_index = max(
        range(len(corrected_temperature)),
        key=lambda index: abs(corrected_temperature[index]),
    )
    hottest_delta = corrected_temperature[hottest_index]
    if abs(hottest_delta) >= TEMPERATURE_DELTA_C_THRESHOLD:
        return (
            "temperature_asymmetry",
            "left" if hottest_delta > 0 else "right",
        )

    return None


def _signal_is_active(
    metric: PairMetric,
    baseline: BaselineProfile,
    signal: tuple[str, str],
) -> bool:
    """Apply lower exit thresholds so one noisy sample cannot reset a risk."""
    if metric.left_total + metric.right_total < RISK_MIN_TOTAL_PRESSURE:
        return False

    risk_type, risk_side = signal
    if risk_type == "left_load_bias":
        return _adjusted_load_bias(metric, baseline) >= LOAD_BIAS_EXIT_THRESHOLD
    if risk_type == "right_load_bias":
        return _adjusted_load_bias(metric, baseline) <= -LOAD_BIAS_EXIT_THRESHOLD
    if risk_type == "forefoot_high":
        return _forefoot_delta(metric, baseline, risk_side) >= (
            FOREFOOT_RATIO_EXIT_THRESHOLD
        )
    if risk_type == "temperature_asymmetry":
        corrected = _temperature_delta_from_baseline(metric, baseline)
        if risk_side == "left":
            return max(corrected) >= TEMPERATURE_DELTA_C_EXIT_THRESHOLD
        return min(corrected) <= -TEMPERATURE_DELTA_C_EXIT_THRESHOLD
    return False


def _current_risk(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[RiskState, PairMetric]:
    latest = _pressure_metric_from_window(metrics)
    current_signal = _signal(latest, baseline)

    # If the newest smoothed sample has moved below an enter threshold but is
    # still above the lower exit threshold, continue the most recent signal.
    # This prevents a sustained posture from being reset by one borderline
    # sample while still requiring every intervening sample to remain active.
    if current_signal is None:
        following = [latest]
        next_metric = latest
        for index in range(len(metrics) - 2, -1, -1):
            metric = _pressure_metric_from_window(metrics, index)
            if (
                metric.sync_id != latest.sync_id
                or next_metric.timestamp_ms - metric.timestamp_ms
                > CONTINUITY_GAP_MS
            ):
                break
            candidate = _signal(metric, baseline)
            if candidate is not None and all(
                _signal_is_active(item, baseline, candidate)
                for item in following
            ):
                current_signal = candidate
                break
            following.append(metric)
            next_metric = metric

    if current_signal is None:
        return (
            RiskState(
                risk_type="normal",
                risk_side="none",
                risk_level=0,
                duration_ms=0,
            ),
            latest,
        )

    start = latest.timestamp_ms
    next_metric = latest
    for index in range(len(metrics) - 2, -1, -1):
        metric = _pressure_metric_from_window(metrics, index)
        if (
            not _signal_is_active(metric, baseline, current_signal)
            or metric.sync_id != latest.sync_id
            or next_metric.timestamp_ms - metric.timestamp_ms
            > CONTINUITY_GAP_MS
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


def _pressure_score(value: float) -> float:
    score = _clamp_score(value)
    return 0.0 if score < REGIONAL_MIN_VISIBLE_SCORE else score


def _regional_analysis(
    metric: PairMetric, baseline: BaselineProfile
) -> RegionalAnalysis:
    displayed_sample_count = min(
        baseline.sample_count, BASELINE_MIN_SAMPLES
    )
    if not baseline.ready:
        return RegionalAnalysis(
            baseline_ready=False,
            baseline_source="layout_default",
            baseline_sample_count=displayed_sample_count,
            baseline_required_samples=BASELINE_MIN_SAMPLES,
            left_pressure_scores=[0.0] * 6,
            right_pressure_scores=[0.0] * 6,
            temperature_delta_c=[
                round(value, 2) for value in metric.temperature_delta_c
            ],
            left_temperature_scores=[0.0] * 4,
            right_temperature_scores=[0.0] * 4,
        )

    left_scores: list[float] = []
    right_scores: list[float] = []
    for index in range(6):
        channel_evidence = (
            metric.left_pressure[index] + metric.right_pressure[index]
        )
        if channel_evidence < REGIONAL_MIN_CHANNEL_EVIDENCE:
            left_scores.append(0.0)
            right_scores.append(0.0)
            continue
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
            _pressure_score(
                max(
                    left_share_change / REGIONAL_SHARE_DELTA_FOR_SEVERE,
                    corrected_asymmetry / REGIONAL_ASYMMETRY_FOR_SEVERE,
                )
            )
        )
        right_scores.append(
            _pressure_score(
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
        baseline_sample_count=displayed_sample_count,
        baseline_required_samples=BASELINE_MIN_SAMPLES,
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


def calibration_status(session: Session) -> CalibrationStatus:
    baseline = _baseline_profile(_pair_history(session))
    state = calibration_state(session)
    return CalibrationStatus(
        baseline_ready=baseline.ready,
        sample_count=min(baseline.sample_count, BASELINE_MIN_SAMPLES),
        required_samples=BASELINE_MIN_SAMPLES,
        reset_at_ms=state.reset_at_ms if state is not None else None,
    )


def restart_calibration(session: Session) -> CalibrationStatus:
    now_ms = int(time() * 1000)
    reset_calibration(session, now_ms)
    session.execute(
        update(RiskEvent)
        .where(RiskEvent.status == "active")
        .values(status="interrupted", ended_at_ms=now_ms)
    )
    session.execute(
        update(Command)
        .where(Command.status == "pending")
        .values(status="expired", error_code="command_expired")
    )
    session.commit()
    return CalibrationStatus(
        baseline_ready=False,
        sample_count=0,
        required_samples=BASELINE_MIN_SAMPLES,
        reset_at_ms=now_ms,
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
        select(Command)
        .where(
            Command.event_id == event.event_id,
            Command.status == "executed",
        )
        .order_by(Command.executed_at_ms.desc())
        .limit(1)
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
    # Keep the event values and the feedback label on the same observation.
    # The history API otherwise combines a stale event.after_load_diff with a
    # freshly updated feedback.effect_label and can display contradictions.
    event.after_load_diff = metric.load_diff
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
    left_latest = latest_frame(session, "left")
    right_latest = latest_frame(session, "right")
    latest_pair = _latest_complete_pair(session, left_latest, right_latest)
    if latest_pair is None:
        risk = RiskState(
            risk_type="data_incomplete", risk_side="none", risk_level=0, duration_ms=0
        )
        if record:
            _record_risk(
                session, risk, None, allow_motor_command=allow_motor_command
            )
        return RealtimeResponse(
            left=to_schema(left_latest) if left_latest else None,
            right=to_schema(right_latest) if right_latest else None,
            paired_timestamp_ms=None,
            sync_error_ms=None,
            load_bias=None,
            load_diff=None,
            motion_state="unavailable",
            risk=risk,
            regional_analysis=None,
        )
    left_model, right_model = latest_pair
    left = to_schema(left_model)
    right = to_schema(right_model)
    metrics = _pair_history(session)
    baseline = _baseline_profile(metrics)
    risk_metrics = metrics or [_metric(left_model, right_model)]
    risk, metric = _current_risk(risk_metrics, baseline)
    if record:
        _record_risk(
            session,
            risk,
            metric,
            allow_motor_command=allow_motor_command and baseline.ready,
        )
    return RealtimeResponse(
        left=left,
        right=right,
        paired_timestamp_ms=metric.timestamp_ms,
        sync_error_ms=abs(left.timestamp_ms - right.timestamp_ms),
        load_bias=metric.load_bias,
        load_diff=metric.load_diff,
        motion_state=metric.motion_state,
        risk=risk,
        regional_analysis=_regional_analysis(metric, baseline),
    )
