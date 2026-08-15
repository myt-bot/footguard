from __future__ import annotations

import json
from dataclasses import dataclass, replace
from math import exp, log, sqrt
from statistics import median, pstdev
from time import time

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ..config import (
    ATTENTION_AFTER_MS,
    BASELINE_ACTIVE_PRESSURE_FLOOR,
    BASELINE_BALANCED_BIAS_MAX,
    BASELINE_CALIBRATION_WINDOW_SAMPLES,
    BASELINE_CHANNEL_MAX_MAD,
    BASELINE_CHANNEL_SATURATION,
    BASELINE_DISTRIBUTION_INLIER_TOLERANCE,
    BASELINE_LOAD_BIAS_INLIER_TOLERANCE,
    BASELINE_MAD_SCALE,
    BASELINE_MIN_ACTIVE_CHANNELS,
    BASELINE_MIN_FOOT_PRESSURE,
    BASELINE_MIN_SAMPLES,
    BASELINE_STABLE_GAP_MS,
    CALIBRATION_SAMPLE_INTERVAL_MS,
    CALIBRATION_INVALID_MASK,
    CONTINUITY_GAP_MS,
    DEFAULT_PRESSURE_DISTRIBUTION,
    FOREFOOT_RATIO_DELTA_THRESHOLD,
    FOREFOOT_RATIO_EXIT_THRESHOLD,
    FOREFOOT_MIN_VALID_CHANNELS,
    FOREFOOT_MIN_ACTIVE_CHANNELS,
    FOREFOOT_MAX_THRESHOLD,
    FOREFOOT_NOISE_MULTIPLIER,
    GAIT_ANALYSIS_WINDOW_MS,
    GAIT_ACTIVE_RECENCY_MS,
    GAIT_CONFIRMED_EPISODE_COUNT,
    GAIT_CONFIRMED_MIN_STEPS,
    GAIT_EPISODE_END_HOLD_MS,
    GAIT_EPISODE_MIN_STEPS,
    GAIT_LOAD_ASYMMETRY_THRESHOLD,
    GAIT_LOAD_SHIFT_THRESHOLD,
    GAIT_MAX_ADAPTIVE_THRESHOLD,
    GAIT_MAX_CADENCE_SPM,
    GAIT_MIN_CADENCE_SPM,
    GAIT_MIN_MOVING_RATIO,
    GAIT_MIN_SIDE_STEPS,
    GAIT_MIN_STEP_CANDIDATES,
    GAIT_MIN_WINDOW_MS,
    GAIT_REGION_DELTA_THRESHOLD,
    GAIT_REGION_REPEAT_RATIO,
    GAIT_STEP_REFRACTORY_MS,
    GAIT_STEP_INTERVAL_CV_THRESHOLD,
    IMU_ACCEL_STATIONARY_TOLERANCE_MS2,
    IMU_ACCEL_DELTA_MOVING_MS2,
    IMU_GRAVITY_MS2,
    IMU_GYRO_STATIONARY_THRESHOLD_DPS,
    IMU_INVALID_MASK,
    IMU_MOTION_HOLD_MS,
    LOAD_BIAS_ENTER_THRESHOLD,
    LOAD_BIAS_EXIT_THRESHOLD,
    LOAD_RATIO_MAX_THRESHOLD,
    LOAD_RATIO_NOISE_MULTIPLIER,
    PAIRING_BLOCK_FLAGS,
    PAIRING_WINDOW_MS,
    PRESSURE_MIN_VALID_CHANNELS_PER_FOOT,
    PRESSURE_CONTACT_ACTIVE_FLOOR,
    PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS,
    PRESSURE_RESIDUAL_FLOOR,
    PRESSURE_RESIDUAL_MAX_MAD,
    PRESSURE_RESIDUAL_MIN_SAMPLES,
    PERSISTENT_AFTER_MS,
    PRESSURE_SMOOTHING_WINDOW_SAMPLES,
    RECOVERY_EFFECTIVE_RATIO,
    RECOVERY_AFTER_WINDOW_MS,
    RECOVERY_BEFORE_WINDOW_MS,
    RECOVERY_MIN_VALID_PAIRS,
    RECOVERY_OBSERVATION_MS,
    RECOVERY_PARTIAL_RATIO,
    REGIONAL_ASYMMETRY_FOR_SEVERE,
    REGIONAL_MIN_CHANNEL_EVIDENCE,
    REGIONAL_MIN_VISIBLE_SCORE,
    REGIONAL_NOISE_MULTIPLIER,
    REGIONAL_RATIO_DELTA_THRESHOLD,
    REGIONAL_RATIO_EXIT_THRESHOLD,
    REGIONAL_SHARE_DELTA_FOR_SEVERE,
    REARFOOT_MIN_VALID_CHANNELS,
    RISK_MIN_TOTAL_PRESSURE,
    RISK_CONTINUITY_GAP_MS,
    RISK_EVENT_CLEAR_HOLD_MS,
    TEMPERATURE_DELTA_C_THRESHOLD,
    TEMPERATURE_DELTA_C_EXIT_THRESHOLD,
    TEMPERATURE_ATTENTION_AFTER_MS,
    TEMPERATURE_CORRECTED_RAW_SUPPORT_C,
    TEMPERATURE_DROPOUT_GRACE_MS,
    TEMPERATURE_PERSISTENT_AFTER_MS,
    TEMPERATURE_RAW_DELTA_C_THRESHOLD,
    TEMPERATURE_WARNING_AFTER_MS,
    WARNING_AFTER_MS,
)
from ..models import (
    CalibrationProfile,
    Command,
    GaitEpisode,
    InterventionFeedback,
    RiskEvent,
    SensorFrame,
)
from ..repositories.calibration_repository import (
    BASELINE_PROFILE_KEY,
    calibration_frame_cutoff,
    calibration_profile,
    calibration_state,
    reset_calibration,
    save_calibration_profile,
)
from ..repositories.event_repository import active_event, feedback_for_event
from ..repositories.sensor_repository import latest_frame, recent_frames, to_schema
from ..schemas import (
    CalibrationStatus,
    GaitEpisodeSummary,
    GaitIssue,
    GaitSummary,
    GaitTrendSummary,
    RegionalAnalysis,
    RealtimeResponse,
    RiskState,
)
from .command_service import ensure_combined_motor_command, ensure_motor_command


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
    temperature_delta_c: tuple[float | None, ...]
    motion_state: str = "unavailable"
    left_motion_state: str = "unavailable"
    right_motion_state: str = "unavailable"
    pressure_valid: bool = True
    left_pressure_valid: tuple[bool, ...] = (True,) * 6
    right_pressure_valid: tuple[bool, ...] = (True,) * 6
    left_temperature_valid: tuple[bool, ...] = (True,) * 4
    right_temperature_valid: tuple[bool, ...] = (True,) * 4
    log_load_ratio: float = 0.0


@dataclass(frozen=True)
class BaselineProfile:
    ready: bool
    sample_count: int
    load_bias: float
    left_distribution: tuple[float, ...]
    right_distribution: tuple[float, ...]
    pressure_asymmetry: tuple[float, ...]
    temperature_delta_c: tuple[float, ...]
    load_ratio: float
    load_ratio_mad: float
    left_forefoot_mad: float
    right_forefoot_mad: float
    regional_share_mad: tuple[float, ...]
    pressure_channel_trust: tuple[bool, ...]
    temperature_valid: tuple[bool, ...]
    pressure_channel_contact_trust: tuple[bool, ...] = (True,) * 12
    empty_temperature_delta_c: tuple[float, ...] = (0.0,) * 4
    empty_temperature_mad_c: tuple[float, ...] = (0.0,) * 4
    empty_temperature_slope_c_per_s: tuple[float, ...] = (0.0,) * 4
    temperature_offset_status: tuple[str, ...] = ("unstable",) * 4
    wearing_temperature_mad_c: tuple[float, ...] = (0.0,) * 4


def _valid_pair(left: SensorFrame, right: SensorFrame) -> bool:
    return (
        left.protocol_version == right.protocol_version == 1
        and left.sync_id != 0
        and left.sync_id == right.sync_id
        and abs(left.timestamp_ms - right.timestamp_ms) <= PAIRING_WINDOW_MS
        and not ((left.quality_flags | right.quality_flags) & PAIRING_BLOCK_FLAGS)
    )


def _pressure_valid(frame: SensorFrame) -> bool:
    if frame.quality_flags & CALIBRATION_INVALID_MASK:
        return False
    return sum(
        _pressure_channel_valid(frame, index) for index in range(6)
    ) >= PRESSURE_MIN_VALID_CHANNELS_PER_FOOT


def _pressure_channel_valid(frame: SensorFrame, index: int) -> bool:
    return not (frame.quality_flags & (1 << index))


def _temperature_channel_valid(frame: SensorFrame, index: int) -> bool:
    return not (frame.quality_flags & (0x40 << index))


def _frame_is_stationary(
    frame: SensorFrame, previous: SensorFrame | None = None
) -> bool | None:
    if frame.quality_flags & IMU_INVALID_MASK:
        return None
    acceleration = sqrt(frame.ax**2 + frame.ay**2 + frame.az**2)
    angular_speed = sqrt(frame.gx**2 + frame.gy**2 + frame.gz**2)
    # Zero vectors are used by mock/legacy frames and must not be mistaken for
    # a physically stationary MPU under gravity.
    if acceleration < 0.5 and angular_speed < 0.5:
        return None
    if previous is not None and not (previous.quality_flags & IMU_INVALID_MASK):
        acceleration_delta = sqrt(
            (frame.ax - previous.ax) ** 2
            + (frame.ay - previous.ay) ** 2
            + (frame.az - previous.az) ** 2
        )
        if acceleration_delta > IMU_ACCEL_DELTA_MOVING_MS2:
            return False
    return (
        abs(acceleration - IMU_GRAVITY_MS2)
        <= IMU_ACCEL_STATIONARY_TOLERANCE_MS2
        and angular_speed <= IMU_GYRO_STATIONARY_THRESHOLD_DPS
    )


def _motion_state(
    left: SensorFrame,
    right: SensorFrame,
    previous_left: SensorFrame | None = None,
    previous_right: SensorFrame | None = None,
) -> str:
    votes = [
        state
        for state in (
            _frame_is_stationary(left, previous_left),
            _frame_is_stationary(right, previous_right),
        )
        if state is not None
    ]
    if not votes:
        return "unavailable"
    return "stationary" if all(votes) else "moving"


def _foot_motion_state(
    frame: SensorFrame, previous: SensorFrame | None = None
) -> str:
    stationary = _frame_is_stationary(frame, previous)
    if stationary is None:
        return "unavailable"
    return "stationary" if stationary else "moving"


def _metric(
    left: SensorFrame,
    right: SensorFrame,
    *,
    motion_state: str | None = None,
    left_motion_state: str | None = None,
    right_motion_state: str | None = None,
) -> PairMetric:
    left_values = [left.p1, left.p2, left.p3, left.p4, left.p5, left.p6]
    right_values = [right.p1, right.p2, right.p3, right.p4, right.p5, right.p6]
    left_temperature = [left.t1, left.t2, left.t3, left.t4]
    right_temperature = [right.t1, right.t2, right.t3, right.t4]
    left_total = sum(left_values)
    right_total = sum(right_values)
    total = max(left_total + right_total, 1e-9)
    bias = (left_total - right_total) / total
    left_pressure_valid = tuple(
        _pressure_channel_valid(left, index) for index in range(6)
    )
    right_pressure_valid = tuple(
        _pressure_channel_valid(right, index) for index in range(6)
    )
    left_temperature_valid = tuple(
        _temperature_channel_valid(left, index) for index in range(4)
    )
    right_temperature_valid = tuple(
        _temperature_channel_valid(right, index) for index in range(4)
    )
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
            left_temperature[index] - right_temperature[index]
            if left_temperature_valid[index] and right_temperature_valid[index]
            else None
            for index in range(4)
        ),
        motion_state=motion_state or _motion_state(left, right),
        left_motion_state=left_motion_state or _foot_motion_state(left),
        right_motion_state=right_motion_state or _foot_motion_state(right),
        pressure_valid=_pressure_valid(left) and _pressure_valid(right),
        left_pressure_valid=left_pressure_valid,
        right_pressure_valid=right_pressure_valid,
        left_temperature_valid=left_temperature_valid,
        right_temperature_valid=right_temperature_valid,
        log_load_ratio=log((left_total + 1e-6) / (right_total + 1e-6)),
    )


def _pair_history(
    session: Session,
    left_device: SensorFrame | None = None,
    right_device: SensorFrame | None = None,
) -> list[PairMetric]:
    pairs: dict[tuple[int, int], dict[str, SensorFrame]] = {}
    state = calibration_state(session)
    stored_profile = calibration_profile(session)
    stored_temperature_status = (
        tuple(json.loads(stored_profile.temperature_offset_status_json))
        if stored_profile is not None
        else ()
    )
    needs_calibration_history = stored_profile is None or not any(
        status not in {"unstable", "raw_invalid"}
        for status in stored_temperature_status
    )
    for frame in recent_frames(
        session,
        limit=6_000 if needs_calibration_history else 2_000,
        after_id=calibration_frame_cutoff(session),
    ):
        # An offline replay inserted after reset can have a new database id
        # while still belonging to the previous wearing session.
        if (
            state is not None
            and state.reset_at_ms is not None
            and frame.timestamp_ms < state.reset_at_ms
        ):
            continue
        expected = left_device if frame.side == "left" else right_device
        if expected is not None and (
            frame.device_id != expected.device_id
            or frame.protocol_version != expected.protocol_version
            or frame.sensor_layout_version != expected.sensor_layout_version
        ):
            continue
        pairs.setdefault((frame.sync_id, frame.packet_seq), {})[frame.side] = frame
    metrics = []
    previous: dict[str, SensorFrame | None] = {"left": None, "right": None}
    moving_until_ms = {"left": 0, "right": 0}
    complete_pairs = [
        pair
        for pair in pairs.values()
        if set(pair) == {"left", "right"}
        and _valid_pair(pair["left"], pair["right"])
    ]
    complete_pairs.sort(
        key=lambda pair: max(pair["left"].timestamp_ms, pair["right"].timestamp_ms)
    )
    for pair in complete_pairs:
        left = pair["left"]
        right = pair["right"]
        timestamp_ms = max(left.timestamp_ms, right.timestamp_ms)
        foot_states: dict[str, str] = {}
        for side, frame in (("left", left), ("right", right)):
            raw_state = _foot_motion_state(frame, previous[side])
            if raw_state == "moving":
                moving_until_ms[side] = timestamp_ms + IMU_MOTION_HOLD_MS
            foot_states[side] = (
                "moving"
                if raw_state == "moving" or timestamp_ms < moving_until_ms[side]
                else raw_state
            )
        available_states = [
            state for state in foot_states.values() if state != "unavailable"
        ]
        motion = (
            "unavailable"
            if not available_states
            else "moving"
            if "moving" in available_states
            else "stationary"
        )
        metrics.append(
            _metric(
                left,
                right,
                motion_state=motion,
                left_motion_state=foot_states["left"],
                right_motion_state=foot_states["right"],
            )
        )
        previous = {"left": left, "right": right}
    return sorted(metrics, key=lambda item: item.timestamp_ms)


def _gait_step_events(
    segment: list[PairMetric], baseline: BaselineProfile
) -> list[tuple[int, str, PairMetric]]:
    if not segment or not baseline.ready:
        return []
    center = baseline.load_ratio
    adaptive_threshold = min(
        GAIT_MAX_ADAPTIVE_THRESHOLD,
        baseline.load_ratio_mad * 4.0 if baseline.ready else 0.0,
    )
    threshold = max(GAIT_LOAD_SHIFT_THRESHOLD, adaptive_threshold)
    events: list[tuple[int, str, PairMetric]] = []
    current_side: str | None = None
    last_event_at_ms: int | None = None
    for metric in segment:
        credible_channels = []
        for side in ("left", "right"):
            raw_valid = (
                metric.left_pressure_valid
                if side == "left"
                else metric.right_pressure_valid
            )
            offset = 0 if side == "left" else 6
            credible_channels.append(
                sum(
                    raw_valid[index]
                    and baseline.pressure_channel_trust[offset + index]
                    and baseline.pressure_channel_contact_trust[offset + index]
                    for index in range(6)
                )
            )
        if (
            metric.motion_state != "moving"
            or not metric.pressure_valid
            or any(
                count < PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
                for count in credible_channels
            )
        ):
            continue
        left_total = _estimated_total(metric, baseline, "left")
        right_total = _estimated_total(metric, baseline, "right")
        if left_total <= 1e-9 or right_total <= 1e-9:
            continue
        shifted_ratio = log((left_total + 1e-6) / (right_total + 1e-6)) - center
        side = (
            "left"
            if shifted_ratio >= threshold
            else "right"
            if shifted_ratio <= -threshold
            else None
        )
        if (
            side is not None
            and side != current_side
            and (
                last_event_at_ms is None
                or metric.timestamp_ms - last_event_at_ms
                >= GAIT_STEP_REFRACTORY_MS
            )
        ):
            events.append((metric.timestamp_ms, side, metric))
            current_side = side
            last_event_at_ms = metric.timestamp_ms
    return events


def _gait_episode_from_segment(
    segment: list[PairMetric], baseline: BaselineProfile
) -> GaitEpisodeSummary | None:
    if not segment:
        return None
    events = _gait_step_events(segment, baseline)
    window_ms = segment[-1].timestamp_ms - segment[0].timestamp_ms
    intervals = [
        events[index][0] - events[index - 1][0]
        for index in range(1, len(events))
        if GAIT_STEP_REFRACTORY_MS
        <= events[index][0] - events[index - 1][0]
        <= 3_000
    ]
    cadence_spm = 60_000.0 / median(intervals) if intervals else None
    moving_ratio = sum(item.motion_state == "moving" for item in segment) / len(segment)
    if not (
        window_ms >= GAIT_MIN_WINDOW_MS
        and moving_ratio >= GAIT_MIN_MOVING_RATIO
        and len(events) >= GAIT_EPISODE_MIN_STEPS
        and cadence_spm is not None
        and GAIT_MIN_CADENCE_SPM <= cadence_spm <= GAIT_MAX_CADENCE_SPM
    ):
        return None

    side_events = {
        side: [metric for _, event_side, metric in events if event_side == side]
        for side in ("left", "right")
    }
    load_indexes = {"left": 0.0, "right": 0.0}
    for index, (event_at_ms, side, metric) in enumerate(events):
        previous_at_ms = events[index - 1][0] if index > 0 else None
        next_at_ms = events[index + 1][0] if index + 1 < len(events) else None
        if previous_at_ms is None and next_at_ms is None:
            support_ms = 0
        elif previous_at_ms is None:
            support_ms = next_at_ms - event_at_ms
        elif next_at_ms is None:
            support_ms = event_at_ms - previous_at_ms
        else:
            support_ms = (next_at_ms - previous_at_ms) / 2
        load_indexes[side] += (
            _estimated_total(metric, baseline, side) * support_ms / 1000.0
        )
    load_sum = load_indexes["left"] + load_indexes["right"]
    load_asymmetry = (
        abs(load_indexes["left"] - load_indexes["right"]) / load_sum
        if load_sum > 1e-9
        else 0.0
    )
    interval_mean = sum(intervals) / len(intervals) if intervals else 0.0
    step_interval_cv = (
        pstdev(intervals) / interval_mean
        if len(intervals) >= 2 and interval_mean > 0
        else 0.0
    )
    region_indices = {
        "forefoot": (0, 1, 2, 3),
        "medial": (0, 3),
        "lateral": (1,),
    }

    def share(metric: PairMetric, side: str, region: str) -> float:
        distribution = _estimated_distribution(metric, baseline, side)
        value = sum(distribution[index] for index in region_indices[region])
        return (
            value
            if region == "forefoot"
            else value / max(sum(distribution[:4]), 1e-9)
        )

    shares = {
        (side, region): median(share(metric, side, region) for metric in side_events[side])
        if side_events[side]
        else 0.0
        for side in ("left", "right")
        for region in region_indices
    }
    baseline_shares = {
        (side, region): (
            sum(
                (baseline.left_distribution if side == "left" else baseline.right_distribution)[index]
                for index in indices
            )
            if region == "forefoot"
            else _regional_distribution_share(
                baseline.left_distribution if side == "left" else baseline.right_distribution,
                region,
            )
        )
        for side in ("left", "right")
        for region, indices in region_indices.items()
    }
    issues: list[GaitIssue] = []
    if (
        all(
            len(side_events[side]) >= GAIT_MIN_SIDE_STEPS
            for side in ("left", "right")
        )
        and load_asymmetry >= GAIT_LOAD_ASYMMETRY_THRESHOLD
    ):
        issues.append(
            GaitIssue(
                issue_type="walking_load_asymmetry",
                side="left" if load_indexes["left"] > load_indexes["right"] else "right",
                value=round(load_asymmetry, 4),
                threshold=GAIT_LOAD_ASYMMETRY_THRESHOLD,
            )
        )
    # The forefoot signal is the only regional walking signal promoted to a
    # formal finding. Medial/lateral shares remain in the episode metrics for
    # engineering review, but their single-step variation is too sensitive to
    # turns and the current sparse sensor layout for user-facing alerts.
    for region, issue_type in (("forefoot", "walking_forefoot_concentration"),):
        for side in ("left", "right"):
            samples = side_events[side]
            if len(samples) < GAIT_MIN_SIDE_STEPS:
                continue
            delta = shares[(side, region)] - baseline_shares[(side, region)]
            repeated = sum(
                share(metric, side, region) - baseline_shares[(side, region)]
                >= GAIT_REGION_DELTA_THRESHOLD
                for metric in samples
            ) / len(samples)
            if delta >= GAIT_REGION_DELTA_THRESHOLD and repeated >= GAIT_REGION_REPEAT_RATIO:
                issues.append(
                    GaitIssue(
                        issue_type=issue_type,
                        side=side,
                        value=round(delta, 4),
                        threshold=GAIT_REGION_DELTA_THRESHOLD,
                    )
                )
    return GaitEpisodeSummary(
        episode_id=f"gait_{segment[-1].sync_id}_{events[0][0]}",
        started_at_ms=events[0][0],
        ended_at_ms=events[-1][0],
        duration_ms=events[-1][0] - events[0][0],
        step_count=len(events),
        left_steps=len(side_events["left"]),
        right_steps=len(side_events["right"]),
        cadence_spm=round(cadence_spm, 1),
        step_interval_cv=round(step_interval_cv, 4),
        left_load_index=round(load_indexes["left"], 4),
        right_load_index=round(load_indexes["right"], 4),
        load_asymmetry=round(load_asymmetry, 4),
        left_forefoot_ratio=round(shares[("left", "forefoot")], 4),
        right_forefoot_ratio=round(shares[("right", "forefoot")], 4),
        left_medial_ratio=round(shares[("left", "medial")], 4),
        right_medial_ratio=round(shares[("right", "medial")], 4),
        left_lateral_ratio=round(shares[("left", "lateral")], 4),
        right_lateral_ratio=round(shares[("right", "lateral")], 4),
        issues=issues,
    )


def _episode_to_model(episode: GaitEpisodeSummary, reset_at_ms: int) -> GaitEpisode:
    metrics = episode.model_dump(exclude={"episode_id", "issues"})
    return GaitEpisode(
        episode_id=episode.episode_id,
        reset_at_ms=reset_at_ms,
        started_at_ms=episode.started_at_ms,
        ended_at_ms=episode.ended_at_ms,
        duration_ms=episode.duration_ms,
        step_count=episode.step_count,
        left_steps=episode.left_steps,
        right_steps=episode.right_steps,
        cadence_spm=episode.cadence_spm,
        step_interval_cv=episode.step_interval_cv,
        left_load_index=episode.left_load_index,
        right_load_index=episode.right_load_index,
        load_asymmetry=episode.load_asymmetry,
        metrics_json=json.dumps(metrics, separators=(",", ":")),
        issues_json=json.dumps(
            [item.model_dump(mode="json") for item in episode.issues],
            separators=(",", ":"),
        ),
    )


def gait_episode_from_model(model: GaitEpisode) -> GaitEpisodeSummary:
    metrics = json.loads(model.metrics_json or "{}")
    return GaitEpisodeSummary(
        episode_id=model.episode_id,
        started_at_ms=model.started_at_ms,
        ended_at_ms=model.ended_at_ms,
        duration_ms=model.duration_ms,
        step_count=model.step_count,
        left_steps=model.left_steps,
        right_steps=model.right_steps,
        cadence_spm=model.cadence_spm,
        step_interval_cv=model.step_interval_cv,
        left_load_index=model.left_load_index,
        right_load_index=model.right_load_index,
        load_asymmetry=model.load_asymmetry,
        left_forefoot_ratio=metrics.get("left_forefoot_ratio", 0.0),
        right_forefoot_ratio=metrics.get("right_forefoot_ratio", 0.0),
        left_medial_ratio=metrics.get("left_medial_ratio", 0.0),
        right_medial_ratio=metrics.get("right_medial_ratio", 0.0),
        left_lateral_ratio=metrics.get("left_lateral_ratio", 0.0),
        right_lateral_ratio=metrics.get("right_lateral_ratio", 0.0),
        issues=[
            GaitIssue.model_validate(item)
            for item in json.loads(model.issues_json or "[]")
        ],
    )


def _episode_matches(left: GaitEpisodeSummary, right: GaitEpisodeSummary) -> bool:
    if left.episode_id == right.episode_id:
        return True
    overlap = max(
        0,
        min(left.ended_at_ms, right.ended_at_ms)
        - max(left.started_at_ms, right.started_at_ms),
    )
    shorter = max(1, min(left.duration_ms, right.duration_ms))
    return overlap / shorter >= 0.80 or (
        abs(left.started_at_ms - right.started_at_ms) <= 1_000
        and abs(left.ended_at_ms - right.ended_at_ms) <= 1_000
    )


def _saved_gait_episodes(
    session: Session | None, reset_at_ms: int, *, limit: int = 50
) -> list[GaitEpisodeSummary]:
    if session is None:
        return []
    models = list(
        session.scalars(
            select(GaitEpisode)
            .where(GaitEpisode.reset_at_ms >= reset_at_ms)
            .order_by(GaitEpisode.ended_at_ms.desc(), GaitEpisode.step_count.desc())
            .limit(limit)
        )
    )
    result: list[GaitEpisodeSummary] = []
    for model in models:
        episode = gait_episode_from_model(model)
        if any(_episode_matches(episode, saved) for saved in result):
            continue
        result.append(episode)
    return result


def _persist_gait_episode(
    session: Session, episode: GaitEpisodeSummary, reset_at_ms: int
) -> None:
    matching_models = [
        model
        for model in session.scalars(
            select(GaitEpisode).where(GaitEpisode.reset_at_ms >= reset_at_ms)
        )
        if _episode_matches(episode, gait_episode_from_model(model))
    ]
    target = session.get(GaitEpisode, episode.episode_id)
    if target is None and matching_models:
        target = matching_models[0]
    if target is None:
        session.add(_episode_to_model(episode, reset_at_ms))
    else:
        updated = _episode_to_model(episode, reset_at_ms)
        target.episode_id = updated.episode_id
        target.reset_at_ms = updated.reset_at_ms
        target.started_at_ms = updated.started_at_ms
        target.ended_at_ms = updated.ended_at_ms
        target.duration_ms = updated.duration_ms
        target.step_count = updated.step_count
        target.left_steps = updated.left_steps
        target.right_steps = updated.right_steps
        target.cadence_spm = updated.cadence_spm
        target.step_interval_cv = updated.step_interval_cv
        target.left_load_index = updated.left_load_index
        target.right_load_index = updated.right_load_index
        target.load_asymmetry = updated.load_asymmetry
        target.metrics_json = updated.metrics_json
        target.issues_json = updated.issues_json
        for duplicate in matching_models:
            if duplicate is not target:
                session.delete(duplicate)
    session.commit()


def _confirmed_gait_trend(
    episodes: list[GaitEpisodeSummary],
) -> tuple[list[GaitIssue], int, int]:
    evidence = episodes[:GAIT_CONFIRMED_EPISODE_COUNT]
    steps = sum(item.step_count for item in evidence)
    if len(evidence) < GAIT_CONFIRMED_EPISODE_COUNT or steps < GAIT_CONFIRMED_MIN_STEPS:
        return [], len(evidence), steps
    keys = {
        (issue.issue_type, issue.side)
        for issue in evidence[0].issues
        if issue.issue_type
        in {"walking_load_asymmetry", "walking_forefoot_concentration"}
    }
    confirmed: list[GaitIssue] = []
    for key in sorted(keys):
        matches = [
            next(
                (
                    issue
                    for issue in episode.issues
                    if (issue.issue_type, issue.side) == key
                ),
                None,
            )
            for episode in evidence
        ]
        if all(item is not None for item in matches):
            values = [item.value for item in matches if item is not None]
            thresholds = [item.threshold for item in matches if item is not None]
            confirmed.append(
                GaitIssue(
                    issue_type=key[0],
                    side=key[1],
                    value=round(median(values), 4),
                    threshold=max(thresholds),
                )
            )
    return confirmed, len(evidence), steps


def gait_history_summary(
    session: Session, reset_at_ms: int, *, limit: int = 8
) -> tuple[list[GaitEpisodeSummary], GaitTrendSummary]:
    episodes = _saved_gait_episodes(session, reset_at_ms, limit=max(limit, 50))
    confirmed, evidence_count, evidence_steps = _confirmed_gait_trend(episodes)
    return episodes[:limit], GaitTrendSummary(
        evidence_episode_count=evidence_count,
        evidence_step_count=evidence_steps,
        confirmed_issues=confirmed,
    )


def _completed_gait_segment(
    metrics: list[PairMetric], last_moving_index: int
) -> list[PairMetric]:
    end_at_ms = metrics[last_moving_index].timestamp_ms
    start_index = last_moving_index
    previous_moving_at_ms = end_at_ms
    for index in range(last_moving_index - 1, -1, -1):
        metric = metrics[index]
        if metric.motion_state != "moving":
            if end_at_ms - metric.timestamp_ms >= GAIT_EPISODE_END_HOLD_MS:
                break
            continue
        if previous_moving_at_ms - metric.timestamp_ms > GAIT_EPISODE_END_HOLD_MS:
            break
        start_index = index
        previous_moving_at_ms = metric.timestamp_ms
    return metrics[start_index : last_moving_index + 1]


def _latest_saved_gait_episode(
    session: Session | None, reset_at_ms: int
) -> GaitEpisodeSummary | None:
    episodes = _saved_gait_episodes(session, reset_at_ms, limit=50)
    return episodes[0] if episodes else None


def _gait_summary(
    metrics: list[PairMetric],
    baseline: BaselineProfile,
    *,
    session: Session | None = None,
    record: bool = False,
) -> GaitSummary:
    if not metrics:
        return GaitSummary(
            state="insufficient_data",
            window_ms=0,
            step_count=0,
            left_steps=0,
            right_steps=0,
        )
    state = calibration_state(session) if session is not None else None
    reset_at_ms = state.reset_at_ms if state and state.reset_at_ms else 0
    latest_at_ms = metrics[-1].timestamp_ms
    recent = [
        item
        for item in metrics
        if item.timestamp_ms >= latest_at_ms - GAIT_ANALYSIS_WINDOW_MS
    ]
    live_episode = _gait_episode_from_segment(recent, baseline)
    live_events = _gait_step_events(recent, baseline)
    live_valid = (
        live_episode is not None
        and metrics[-1].motion_state == "moving"
        and bool(live_events)
        and latest_at_ms - live_events[-1][0] <= GAIT_ACTIVE_RECENCY_MS
    )

    completed: GaitEpisodeSummary | None = None
    last_moving_index = next(
        (
            index
            for index in range(len(metrics) - 1, -1, -1)
            if metrics[index].motion_state == "moving"
        ),
        None,
    )
    if (
        last_moving_index is not None
        and latest_at_ms - metrics[last_moving_index].timestamp_ms
        >= GAIT_EPISODE_END_HOLD_MS
    ):
        completed_segment = _completed_gait_segment(metrics, last_moving_index)
        completed = _gait_episode_from_segment(completed_segment, baseline)
        if completed is not None and record and session is not None:
            _persist_gait_episode(session, completed, reset_at_ms)
    saved_episodes = _saved_gait_episodes(session, reset_at_ms)
    last_completed = completed or (saved_episodes[0] if saved_episodes else None)
    confirmed_issues, evidence_episode_count, evidence_step_count = (
        _confirmed_gait_trend(saved_episodes)
    )
    window_ms = recent[-1].timestamp_ms - recent[0].timestamp_ms if recent else 0
    if live_valid and live_episode is not None:
        return GaitSummary(
            state="walking",
            window_ms=window_ms,
            step_count=live_episode.step_count,
            left_steps=live_episode.left_steps,
            right_steps=live_episode.right_steps,
            cadence_spm=live_episode.cadence_spm,
            last_completed_episode=last_completed,
            confirmed_issues=confirmed_issues,
            evidence_episode_count=evidence_episode_count,
            evidence_step_count=evidence_step_count,
        )
    return GaitSummary(
        state=(
            "stationary"
            if metrics[-1].motion_state == "stationary"
            else "insufficient_data"
        ),
        window_ms=window_ms,
        step_count=0,
        left_steps=0,
        right_steps=0,
        last_completed_episode=last_completed,
        confirmed_issues=confirmed_issues,
        evidence_episode_count=evidence_episode_count,
        evidence_step_count=evidence_step_count,
    )


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
        if metric.pressure_valid
        and metric.sync_id == reference.sync_id
        and reference.timestamp_ms - metric.timestamp_ms
        <= CONTINUITY_GAP_MS * PRESSURE_SMOOTHING_WINDOW_SAMPLES
    ]
    if not window:
        window = [reference]
    left_pressure = tuple(
        median(values)
        if (
            values := [
                metric.left_pressure[index]
                for metric in window
                if metric.left_pressure_valid[index]
            ]
        )
        else reference.left_pressure[index]
        for index in range(6)
    )
    right_pressure = tuple(
        median(values)
        if (
            values := [
                metric.right_pressure[index]
                for metric in window
                if metric.right_pressure_valid[index]
            ]
        )
        else reference.right_pressure[index]
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
        left_motion_state=reference.left_motion_state,
        right_motion_state=reference.right_motion_state,
        pressure_valid=reference.pressure_valid,
        left_pressure_valid=reference.left_pressure_valid,
        right_pressure_valid=reference.right_pressure_valid,
        left_temperature_valid=reference.left_temperature_valid,
        right_temperature_valid=reference.right_temperature_valid,
        log_load_ratio=log((left_total + 1e-6) / (right_total + 1e-6)),
    )


def _median_channels(
    metrics: list[PairMetric], field: str, channel_count: int
) -> tuple[float, ...]:
    return tuple(
        median(getattr(metric, field)[index] for metric in metrics)
        for index in range(channel_count)
    )


def _mad(values: list[float], center: float | None = None) -> float:
    if not values:
        return 0.0
    resolved_center = median(values) if center is None else center
    return median(abs(value - resolved_center) for value in values) * BASELINE_MAD_SCALE


def _metric_log_load_ratio(metric: PairMetric) -> float:
    return log((metric.left_total + 1e-6) / (metric.right_total + 1e-6))


def _empty_baseline(sample_count: int = 0) -> BaselineProfile:
    return BaselineProfile(
        ready=False,
        sample_count=sample_count,
        load_bias=0.0,
        left_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
        right_distribution=DEFAULT_PRESSURE_DISTRIBUTION,
        pressure_asymmetry=(0.0,) * 6,
        temperature_delta_c=(0.0,) * 4,
        load_ratio=0.0,
        load_ratio_mad=0.0,
        left_forefoot_mad=0.0,
        right_forefoot_mad=0.0,
        regional_share_mad=(0.0,) * 4,
        pressure_channel_trust=(True,) * 12,
        temperature_valid=(False,) * 4,
        pressure_channel_contact_trust=(True,) * 12,
    )


def _empty_temperature_reference(
    metrics: list[PairMetric],
) -> tuple[tuple[float, ...], tuple[float, ...], tuple[float, ...], tuple[str, ...]]:
    """Extract the initial no-load temperature run after a re-wear reset."""
    run: list[PairMetric] = []
    for metric in metrics:
        left_contact_points = sum(
            valid and value >= PRESSURE_CONTACT_ACTIVE_FLOOR
            for valid, value in zip(
                metric.left_pressure_valid, metric.left_pressure, strict=True
            )
        )
        right_contact_points = sum(
            valid and value >= PRESSURE_CONTACT_ACTIVE_FLOOR
            for valid, value in zip(
                metric.right_pressure_valid, metric.right_pressure, strict=True
            )
        )
        no_load = (
            left_contact_points < PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS
            and right_contact_points < PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS
        )
        if not no_load:
            if run:
                break
            continue
        if run and metric.timestamp_ms - run[-1].timestamp_ms > CONTINUITY_GAP_MS:
            break
        run.append(metric)
    if not run:
        return (0.0,) * 4, (0.0,) * 4, (0.0,) * 4, ("unstable",) * 4
    # The warm-up period is deliberately discarded so glue/contact drift is
    # not mistaken for an assembly offset.
    warmup_end = run[0].timestamp_ms + 15_000
    stable = _time_gated_calibration_samples(
        [metric for metric in run if metric.timestamp_ms >= warmup_end]
    )
    if len(stable) < 60:
        return (0.0,) * 4, (0.0,) * 4, (0.0,) * 4, ("unstable",) * 4
    stable = stable[:60]
    deltas: list[list[float]] = [
        [metric.temperature_delta_c[index] for metric in stable if metric.temperature_delta_c[index] is not None]
        for index in range(4)
    ]
    centers = tuple(median(values) if values else 0.0 for values in deltas)
    mads = tuple(_mad(values, centers[index]) for index, values in enumerate(deltas))
    elapsed = max((stable[-1].timestamp_ms - stable[0].timestamp_ms) / 1000.0, 1.0)
    slopes = tuple(
        ((next((m.temperature_delta_c[index] for m in reversed(stable) if m.temperature_delta_c[index] is not None), centers[index]) -
          next((m.temperature_delta_c[index] for m in stable if m.temperature_delta_c[index] is not None), centers[index])) / elapsed)
        for index in range(4)
    )
    statuses = tuple(
        "raw_invalid"
        if len(deltas[index]) < BASELINE_MIN_SAMPLES
        else "assembly_offset"
        if abs(centers[index]) >= 2.2 and mads[index] <= 0.6 and abs(slopes[index]) <= 0.05
        else "normal_offset"
        if mads[index] <= 0.6 and abs(slopes[index]) <= 0.05
        else "unstable"
        for index in range(4)
    )
    return centers, mads, slopes, statuses


def _active_channel_count(values: tuple[float, ...]) -> int:
    return sum(value >= BASELINE_ACTIVE_PRESSURE_FLOOR for value in values)


def _is_baseline_candidate(metric: PairMetric) -> bool:
    return (
        # Do not learn a walking/transient frame as the user's standing
        # reference. Missing MPU data deliberately fails open.
        metric.pressure_valid
        and all(metric.left_pressure_valid)
        and all(metric.right_pressure_valid)
        and metric.motion_state != "moving"
        and metric.left_total >= BASELINE_MIN_FOOT_PRESSURE
        and metric.right_total >= BASELINE_MIN_FOOT_PRESSURE
        and _active_channel_count(metric.left_pressure)
        >= BASELINE_MIN_ACTIVE_CHANNELS
        and _active_channel_count(metric.right_pressure)
        >= BASELINE_MIN_ACTIVE_CHANNELS
        and abs(metric.load_bias) <= BASELINE_BALANCED_BIAS_MAX
    )


def _time_gated_calibration_samples(
    metrics: list[PairMetric],
) -> list[PairMetric]:
    sampled: list[PairMetric] = []
    last_sample_at_ms: int | None = None
    for metric in metrics:
        if (
            last_sample_at_ms is None
            or metric.timestamp_ms - last_sample_at_ms
            >= CALIBRATION_SAMPLE_INTERVAL_MS
        ):
            sampled.append(metric)
            last_sample_at_ms = metric.timestamp_ms
    return sampled


def _baseline_profile(metrics: list[PairMetric]) -> BaselineProfile:
    # Lock the first stable bilateral-bearing window. Using the newest window
    # would slowly redefine a sustained abnormal posture as the new normal.
    # Do not assemble a baseline from samples separated by a pause, BLE gap,
    # or an unobserved movement. A new wearer must provide one coherent stable
    # standing window.
    runs: list[list[PairMetric]] = []
    current_run: list[PairMetric] = []
    for metric in metrics:
        if not _is_baseline_candidate(metric):
            if current_run:
                runs.append(current_run)
                current_run = []
            continue
        if (
            current_run
            and metric.timestamp_ms - current_run[-1].timestamp_ms
            > BASELINE_STABLE_GAP_MS
        ):
            runs.append(current_run)
            current_run = []
        current_run.append(metric)
    if current_run:
        runs.append(current_run)
    sampled_runs = [_time_gated_calibration_samples(run) for run in runs]
    candidates = max(sampled_runs, key=len, default=[])[
        :BASELINE_CALIBRATION_WINDOW_SAMPLES
    ]
    if len(candidates) < BASELINE_MIN_SAMPLES:
        return _empty_baseline(len(candidates))

    center_load_bias = median(metric.load_bias for metric in candidates)
    center_left_distribution = _median_channels(
        candidates, "left_distribution", 6
    )
    center_right_distribution = _median_channels(
        candidates, "right_distribution", 6
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
    ]
    if len(inliers) < BASELINE_MIN_SAMPLES:
        return _empty_baseline(len(inliers))

    temperature_values = [
        [
            metric.temperature_delta_c[index]
            for metric in inliers
            if metric.temperature_delta_c[index] is not None
        ]
        for index in range(4)
    ]
    temperature_valid = tuple(
        len(values) >= BASELINE_MIN_SAMPLES for values in temperature_values
    )
    load_ratio_values = [_metric_log_load_ratio(metric) for metric in inliers]
    load_ratio = median(load_ratio_values)
    left_forefoot = [metric.left_forefoot_ratio for metric in inliers]
    right_forefoot = [metric.right_forefoot_ratio for metric in inliers]
    regional_series = [
        [
            _regional_distribution_share(metric.left_distribution, region)
            for metric in inliers
        ]
        for region in ("medial", "lateral")
    ] + [
        [
            _regional_distribution_share(metric.right_distribution, region)
            for metric in inliers
        ]
        for region in ("medial", "lateral")
    ]
    channel_series = [
        [getattr(metric, side)[index] for metric in inliers]
        for side in ("left_pressure", "right_pressure")
        for index in range(6)
    ]
    channel_trust = tuple(
        sum(value >= BASELINE_ACTIVE_PRESSURE_FLOOR for value in values)
        >= max(5, len(inliers) // 5)
        and median(values) < BASELINE_CHANNEL_SATURATION
        and _mad(values) <= BASELINE_CHANNEL_MAX_MAD
        for values in channel_series
    )
    if (
        sum(channel_trust[:6]) < PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
        or sum(channel_trust[6:]) < PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
    ):
        return _empty_baseline(len(inliers))
    empty_delta, empty_mad, empty_slope, offset_status = _empty_temperature_reference(metrics)
    wearing_mad = tuple(
        _mad(values, median(values)) if values else 0.0
        for values in temperature_values
    )
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
        temperature_delta_c=tuple(
            median(values) if temperature_valid[index] else 0.0
            for index, values in enumerate(temperature_values)
        ),
        load_ratio=load_ratio,
        load_ratio_mad=_mad(load_ratio_values, load_ratio),
        left_forefoot_mad=_mad(left_forefoot),
        right_forefoot_mad=_mad(right_forefoot),
        regional_share_mad=tuple(_mad(values) for values in regional_series),
        pressure_channel_trust=channel_trust,
        temperature_valid=temperature_valid,
        pressure_channel_contact_trust=channel_trust,
        empty_temperature_delta_c=empty_delta,
        empty_temperature_mad_c=empty_mad,
        empty_temperature_slope_c_per_s=empty_slope,
        temperature_offset_status=offset_status,
        wearing_temperature_mad_c=wearing_mad,
    )


def _profile_to_model(
    profile: BaselineProfile,
    left: SensorFrame,
    right: SensorFrame,
) -> CalibrationProfile:
    return CalibrationProfile(
        profile_key=BASELINE_PROFILE_KEY,
        protocol_version=left.protocol_version,
        sensor_layout_version=left.sensor_layout_version,
        left_device_id=left.device_id,
        right_device_id=right.device_id,
        sample_count=profile.sample_count,
        created_at_ms=max(left.timestamp_ms, right.timestamp_ms),
        load_ratio=profile.load_ratio,
        load_ratio_mad=profile.load_ratio_mad,
        left_distribution_json=json.dumps(profile.left_distribution),
        right_distribution_json=json.dumps(profile.right_distribution),
        left_forefoot_mad=profile.left_forefoot_mad,
        right_forefoot_mad=profile.right_forefoot_mad,
        regional_share_mad_json=json.dumps(profile.regional_share_mad),
        pressure_asymmetry_json=json.dumps(profile.pressure_asymmetry),
        pressure_channel_trust_json=json.dumps(profile.pressure_channel_trust),
        temperature_delta_json=json.dumps(profile.temperature_delta_c),
        temperature_valid_json=json.dumps(profile.temperature_valid),
        empty_temperature_delta_json=json.dumps(profile.empty_temperature_delta_c),
        empty_temperature_mad_json=json.dumps(profile.empty_temperature_mad_c),
        empty_temperature_slope_json=json.dumps(profile.empty_temperature_slope_c_per_s),
        temperature_offset_status_json=json.dumps(profile.temperature_offset_status),
        wearing_temperature_mad_json=json.dumps(profile.wearing_temperature_mad_c),
    )


def _profile_from_model(model: CalibrationProfile) -> BaselineProfile:
    pressure_channel_trust = tuple(
        json.loads(model.pressure_channel_trust_json)
    )
    if len(pressure_channel_trust) == 6:
        pressure_channel_trust = pressure_channel_trust * 2
    def _json_tuple(name: str, default: tuple) -> tuple:
        raw = getattr(model, name, None)
        try:
            values = tuple(json.loads(raw)) if raw else default
        except (TypeError, ValueError, json.JSONDecodeError):
            values = default
        return values if len(values) == len(default) else default

    return BaselineProfile(
        ready=True,
        sample_count=model.sample_count,
        load_bias=(2.0 / (1.0 + exp(-model.load_ratio))) - 1.0,
        left_distribution=tuple(json.loads(model.left_distribution_json)),
        right_distribution=tuple(json.loads(model.right_distribution_json)),
        pressure_asymmetry=tuple(json.loads(model.pressure_asymmetry_json)),
        temperature_delta_c=tuple(json.loads(model.temperature_delta_json)),
        load_ratio=model.load_ratio,
        load_ratio_mad=model.load_ratio_mad,
        left_forefoot_mad=model.left_forefoot_mad,
        right_forefoot_mad=model.right_forefoot_mad,
        regional_share_mad=_json_tuple(
            "regional_share_mad_json", (0.0,) * 4
        ),
        pressure_channel_trust=pressure_channel_trust,
        temperature_valid=tuple(json.loads(model.temperature_valid_json)),
        pressure_channel_contact_trust=pressure_channel_trust,
        empty_temperature_delta_c=_json_tuple("empty_temperature_delta_json", (0.0,) * 4),
        empty_temperature_mad_c=_json_tuple("empty_temperature_mad_json", (0.0,) * 4),
        empty_temperature_slope_c_per_s=_json_tuple("empty_temperature_slope_json", (0.0,) * 4),
        temperature_offset_status=_json_tuple("temperature_offset_status_json", ("unstable",) * 4),
        wearing_temperature_mad_c=_json_tuple("wearing_temperature_mad_json", (0.0,) * 4),
    )


def _saved_baseline(
    session: Session,
    left: SensorFrame,
    right: SensorFrame,
) -> BaselineProfile | None:
    model = calibration_profile(session)
    if model is None:
        return None
    if (
        model.protocol_version != left.protocol_version
        or model.sensor_layout_version != left.sensor_layout_version
        or model.left_device_id != left.device_id
        or model.right_device_id != right.device_id
    ):
        return None
    return _profile_from_model(model)


def _estimated_distribution(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> tuple[float, ...]:
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    raw_valid = (
        metric.left_pressure_valid if side == "left" else metric.right_pressure_valid
    )
    trust_offset = 0 if side == "left" else 6
    valid = tuple(
        raw_valid[index] and baseline.pressure_channel_trust[trust_offset + index]
        for index in range(6)
    )
    reference = (
        baseline.left_distribution
        if side == "left"
        else baseline.right_distribution
    )
    valid_reference_share = sum(
        reference[index] for index in range(6) if valid[index]
    )
    valid_pressure = sum(pressure[index] for index in range(6) if valid[index])
    if valid_reference_share <= 1e-9 or valid_pressure <= 1e-9:
        return reference
    estimated_total = valid_pressure / valid_reference_share
    return tuple(
        pressure[index] / estimated_total if valid[index] else reference[index]
        for index in range(6)
    )


def _estimated_total(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> float:
    if (
        baseline.ready
        and _pressure_contact_count(metric, baseline, side)
        < PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS
    ):
        return 0.0
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    raw_valid = (
        metric.left_pressure_valid if side == "left" else metric.right_pressure_valid
    )
    trust_offset = 0 if side == "left" else 6
    valid = tuple(
        raw_valid[index]
        and baseline.pressure_channel_contact_trust[trust_offset + index]
        for index in range(6)
    )
    reference = (
        baseline.left_distribution
        if side == "left"
        else baseline.right_distribution
    )
    reference_share = sum(reference[index] for index in range(6) if valid[index])
    observed = sum(pressure[index] for index in range(6) if valid[index])
    return observed / max(reference_share, 1e-9)


def _adjusted_load_bias(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> float:
    left_total = _estimated_total(metric, baseline, "left")
    right_total = _estimated_total(metric, baseline, "right")
    current_ratio = log(
        (left_total + 1e-6) / (right_total + 1e-6)
    )
    return current_ratio - baseline.load_ratio


def _load_bias_threshold(
    baseline: BaselineProfile, *, exit_threshold: bool = False
) -> float:
    engineering = (
        LOAD_BIAS_EXIT_THRESHOLD if exit_threshold else LOAD_BIAS_ENTER_THRESHOLD
    )
    engineering_log_ratio = log((1.0 + engineering) / (1.0 - engineering))
    noise = baseline.load_ratio_mad * LOAD_RATIO_NOISE_MULTIPLIER
    return min(max(engineering_log_ratio, noise), LOAD_RATIO_MAX_THRESHOLD)


def _temperature_pair_count(metric: PairMetric) -> int:
    return sum(value is not None for value in metric.temperature_delta_c)


def _forefoot_threshold(
    baseline: BaselineProfile,
    side: str,
    *,
    exit_threshold: bool = False,
) -> float:
    engineering = (
        FOREFOOT_RATIO_EXIT_THRESHOLD
        if exit_threshold
        else FOREFOOT_RATIO_DELTA_THRESHOLD
    )
    noise = (
        baseline.left_forefoot_mad
        if side == "left"
        else baseline.right_forefoot_mad
    ) * FOREFOOT_NOISE_MULTIPLIER
    return min(max(engineering, noise), FOREFOOT_MAX_THRESHOLD)


def _forefoot_delta(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> float:
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    baseline_distribution = (
        baseline.left_distribution
        if side == "left"
        else baseline.right_distribution
    )
    usable = tuple(
        _runtime_pressure_channel_usable(metric, baseline, side, index)
        for index in range(6)
    )
    current_total = sum(
        pressure[index] for index in range(6) if usable[index]
    )
    baseline_total = sum(
        baseline_distribution[index]
        for index in range(6)
        if usable[index]
    )
    if current_total <= 1e-9 or baseline_total <= 1e-9:
        return 0.0
    current_forefoot = sum(
        pressure[index] for index in range(4) if usable[index]
    ) / current_total
    baseline_forefoot = sum(
        baseline_distribution[index]
        for index in range(4)
        if usable[index]
    ) / baseline_total
    return current_forefoot - baseline_forefoot


def _regional_indices(region: str) -> tuple[int, ...]:
    return (0, 3) if region == "medial" else (1,)


def _regional_distribution_share(
    distribution: tuple[float, ...], region: str
) -> float:
    forefoot = sum(distribution[:4])
    return (
        sum(distribution[index] for index in _regional_indices(region))
        / max(forefoot, 1e-9)
    )


def _regional_mad_index(side: str, region: str) -> int:
    return (0 if side == "left" else 2) + (0 if region == "medial" else 1)


def _regional_threshold(
    baseline: BaselineProfile,
    side: str,
    region: str,
    *,
    exit_threshold: bool = False,
) -> float:
    engineering = (
        REGIONAL_RATIO_EXIT_THRESHOLD
        if exit_threshold
        else REGIONAL_RATIO_DELTA_THRESHOLD
    )
    noise = (
        baseline.regional_share_mad[_regional_mad_index(side, region)]
        * REGIONAL_NOISE_MULTIPLIER
    )
    return max(engineering, noise)


def _regional_delta(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
    region: str,
) -> float:
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    distribution = (
        baseline.left_distribution if side == "left" else baseline.right_distribution
    )
    usable = tuple(
        _runtime_pressure_channel_usable(metric, baseline, side, index)
        for index in range(6)
    )
    current_forefoot = sum(pressure[index] for index in range(4) if usable[index])
    if current_forefoot <= 1e-9:
        return 0.0
    indices = _regional_indices(region)
    current_share = sum(
        pressure[index] for index in indices if usable[index]
    ) / current_forefoot
    baseline_forefoot = sum(
        (
            distribution[index]
            if distribution[index] >= BASELINE_ACTIVE_PRESSURE_FLOOR
            else DEFAULT_PRESSURE_DISTRIBUTION[index]
        )
        for index in range(4)
        if usable[index]
    )
    baseline_share = sum(
        (
            distribution[index]
            if distribution[index] >= BASELINE_ACTIVE_PRESSURE_FLOOR
            else DEFAULT_PRESSURE_DISTRIBUTION[index]
        )
        for index in indices
        if usable[index]
    ) / max(baseline_forefoot, 1e-9)
    return current_share - baseline_share


def _regional_supported(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
    region: str,
) -> bool:
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    return (
        _pressure_contact_count(metric, baseline, side)
        >= PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS
        and any(
            _runtime_pressure_channel_usable(metric, baseline, side, index)
            and pressure[index] >= PRESSURE_CONTACT_ACTIVE_FLOOR
            for index in _regional_indices(region)
        )
    )


def _runtime_pressure_channel_usable(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
    index: int,
) -> bool:
    """Allow coordinated current pressure to recover a baseline-uncovered FSR.

    A channel that was quiet during standing calibration is not necessarily
    faulty: a strong forefoot lean can activate it later. In contrast, a
    baseline-trusted channel later diagnosed as residual remains excluded.
    """
    raw_valid = (
        metric.left_pressure_valid if side == "left" else metric.right_pressure_valid
    )
    if not raw_valid[index]:
        return False
    trust_offset = 0 if side == "left" else 6
    channel = trust_offset + index
    if baseline.pressure_channel_contact_trust[channel]:
        return True
    if baseline.pressure_channel_trust[channel]:
        return False
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    return (
        PRESSURE_CONTACT_ACTIVE_FLOOR
        <= pressure[index]
        < BASELINE_CHANNEL_SATURATION
    )


def _forefoot_supported(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> bool:
    raw_valid = (
        metric.left_pressure_valid if side == "left" else metric.right_pressure_valid
    )
    trust_offset = 0 if side == "left" else 6
    valid = tuple(
        raw_valid[index]
        and (
            baseline.pressure_channel_trust[trust_offset + index]
            or _runtime_pressure_channel_usable(metric, baseline, side, index)
        )
        for index in range(6)
    )
    active = tuple(
        _runtime_pressure_channel_usable(metric, baseline, side, index)
        and pressure >= PRESSURE_CONTACT_ACTIVE_FLOOR
        for index, pressure in enumerate(
            metric.left_pressure if side == "left" else metric.right_pressure
        )
    )
    return (
        sum(valid[:4]) >= FOREFOOT_MIN_VALID_CHANNELS
        and sum(valid[4:]) >= REARFOOT_MIN_VALID_CHANNELS
        and sum(active[:4]) >= FOREFOOT_MIN_ACTIVE_CHANNELS
    )


def _pressure_supported(metric: PairMetric, baseline: BaselineProfile) -> bool:
    return all(
        sum(
            raw_valid[index]
            and baseline.pressure_channel_contact_trust[trust_offset + index]
            for index in range(6)
        )
        >= PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
        for raw_valid, trust_offset in (
            (metric.left_pressure_valid, 0),
            (metric.right_pressure_valid, 6),
        )
    )


def _residual_suspect_channels(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[bool, ...]:
    """Find a stable high channel while all other channels show no contact."""
    suspects: list[bool] = []
    for side_index, side in enumerate(("left", "right")):
        trust_offset = side_index * 6
        for channel in range(6):
            unloaded_values: list[float] = []
            for metric in metrics[-500:]:
                pressure = metric.left_pressure if side == "left" else metric.right_pressure
                raw_valid = (
                    metric.left_pressure_valid
                    if side == "left"
                    else metric.right_pressure_valid
                )
                if not raw_valid[channel]:
                    continue
                other_active = 0
                for other_side_index, other_side in enumerate(("left", "right")):
                    other_pressure = (
                        metric.left_pressure
                        if other_side == "left"
                        else metric.right_pressure
                    )
                    other_raw_valid = (
                        metric.left_pressure_valid
                        if other_side == "left"
                        else metric.right_pressure_valid
                    )
                    other_offset = other_side_index * 6
                    other_active += sum(
                        other_raw_valid[index]
                        and baseline.pressure_channel_trust[other_offset + index]
                        and not (other_side == side and index == channel)
                        and other_pressure[index] >= PRESSURE_CONTACT_ACTIVE_FLOOR
                        for index in range(6)
                    )
                if other_active < PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS:
                    unloaded_values.append(pressure[channel])
            suspects.append(
                len(unloaded_values) >= PRESSURE_RESIDUAL_MIN_SAMPLES
                and median(unloaded_values) >= PRESSURE_RESIDUAL_FLOOR
                and _mad(unloaded_values) <= PRESSURE_RESIDUAL_MAX_MAD
            )
    return tuple(suspects)


def _diagnosed_baseline(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[BaselineProfile, tuple[bool, ...]]:
    if not baseline.ready:
        return baseline, _prebaseline_residual_suspect_channels(metrics)
    residual = _residual_suspect_channels(metrics, baseline)
    contact_trust = tuple(
        baseline.pressure_channel_trust[index] and not residual[index]
        for index in range(12)
    )
    if contact_trust == baseline.pressure_channel_contact_trust:
        return baseline, residual
    return replace(
        baseline,
        pressure_channel_contact_trust=contact_trust,
    ), residual


def _prebaseline_residual_suspect_channels(
    metrics: list[PairMetric],
) -> tuple[bool, ...]:
    """Find fixed single-point pressure before a personal baseline exists."""
    recent = metrics[-max(PRESSURE_RESIDUAL_MIN_SAMPLES, 30) :]
    if len(recent) < PRESSURE_RESIDUAL_MIN_SAMPLES:
        return (False,) * 12
    suspects: list[bool] = []
    for side in ("left", "right"):
        for channel in range(6):
            values: list[float] = []
            sparse_frames = 0
            for metric in recent:
                pressure = (
                    metric.left_pressure if side == "left" else metric.right_pressure
                )
                valid = (
                    metric.left_pressure_valid
                    if side == "left"
                    else metric.right_pressure_valid
                )
                if not valid[channel]:
                    continue
                values.append(pressure[channel])
                other_active = sum(
                    valid[index]
                    and index != channel
                    and pressure[index] >= PRESSURE_CONTACT_ACTIVE_FLOOR
                    for index in range(6)
                )
                if other_active < PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS:
                    sparse_frames += 1
            suspects.append(
                len(values) >= PRESSURE_RESIDUAL_MIN_SAMPLES
                and sparse_frames >= int(len(values) * 0.8)
                and median(values) >= PRESSURE_RESIDUAL_FLOOR
                and _mad(values) <= PRESSURE_RESIDUAL_MAX_MAD
            )
    return tuple(suspects)


def _pressure_contact_count(
    metric: PairMetric,
    baseline: BaselineProfile,
    side: str,
) -> int:
    pressure = metric.left_pressure if side == "left" else metric.right_pressure
    raw_valid = (
        metric.left_pressure_valid if side == "left" else metric.right_pressure_valid
    )
    trust_offset = 0 if side == "left" else 6
    return sum(
        raw_valid[index]
        and _runtime_pressure_channel_usable(metric, baseline, side, index)
        and pressure[index] >= PRESSURE_CONTACT_ACTIVE_FLOOR
        for index in range(6)
    )


def _pressure_contact_present(metric: PairMetric, baseline: BaselineProfile) -> bool:
    """Require multi-point contact before interpreting load ratios as risk.

    Unloaded FSRs can retain a stable residual value on one channel. A single
    point is therefore not sufficient evidence for a foot, while a genuine
    standing or one-foot load normally activates multiple trusted channels.
    """
    return any(
        _pressure_contact_count(metric, baseline, side)
        >= PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS
        for side in ("left", "right")
    )


def _temperature_delta_from_baseline(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> tuple[float | None, ...]:
    return tuple(
        value - baseline.temperature_delta_c[index]
        if value is not None and baseline.temperature_valid[index]
        else None
        for index, value in enumerate(metric.temperature_delta_c)
    )


def _temperature_signal_side(
    metric: PairMetric,
    baseline: BaselineProfile,
    *,
    use_exit_threshold: bool = False,
) -> str | None:
    """Return the side supported by compensated, stable temperature evidence."""
    if not baseline.ready or _temperature_pair_count(metric) < 2:
        return None
    threshold = TEMPERATURE_DELTA_C_EXIT_THRESHOLD if use_exit_threshold else TEMPERATURE_DELTA_C_THRESHOLD
    valid_zones = 0
    candidates: list[tuple[float, float]] = []
    for index, (raw, corrected, status, mad) in enumerate(zip(
        metric.temperature_delta_c,
        _temperature_delta_from_baseline(metric, baseline),
        baseline.temperature_offset_status,
        baseline.wearing_temperature_mad_c,
        strict=True,
    )):
        if raw is None or corrected is None or status in {"raw_invalid", "unstable"}:
            continue
        valid_zones += 1
        zone_threshold = max(threshold, (3.0 if not use_exit_threshold else 2.0) * mad)
        if abs(corrected) >= zone_threshold and abs(raw) >= TEMPERATURE_CORRECTED_RAW_SUPPORT_C:
            candidates.append((abs(corrected) / zone_threshold, corrected))
        # Normal-offset zones retain an absolute safety fallback. Assembly
        # offsets are intentionally relative-only to avoid persistent alarms.
        if status == "normal_offset":
            # A raw value below the enter threshold must not keep an event
            # alive after the actual heated region has recovered.
            raw_threshold = TEMPERATURE_RAW_DELTA_C_THRESHOLD
            if abs(raw) >= raw_threshold:
                candidates.append((abs(raw) / raw_threshold, raw))
    if valid_zones < 2 or not candidates:
        return None
    _, strongest_delta = max(candidates, key=lambda candidate: candidate[0])
    return "left" if strongest_delta > 0 else "right"


def _signal(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> tuple[str, str] | None:
    # Temperature is display-only until a complete wearing baseline exists.
    temperature_side = _temperature_signal_side(metric, baseline)
    if temperature_side is not None:
        return "temperature_asymmetry", temperature_side

    # Walking pressure is evaluated by the step-based gait analyzer. Static
    # pressure rules must not interpret a stance phase as a sustained risk.
    if metric.motion_state == "moving":
        return None

    # Pressure risks still require meaningful footwear loading.
    if (
        not metric.pressure_valid
        or not baseline.ready
        or not _pressure_supported(metric, baseline)
    ):
        return None
    if (
        _estimated_total(metric, baseline, "left")
        + _estimated_total(metric, baseline, "right")
        < RISK_MIN_TOTAL_PRESSURE
        or not _pressure_contact_present(metric, baseline)
    ):
        return None
    adjusted_bias = _adjusted_load_bias(metric, baseline)
    if adjusted_bias >= _load_bias_threshold(baseline):
        return "left_load_bias", "left"
    if adjusted_bias <= -_load_bias_threshold(baseline):
        return "right_load_bias", "right"

    if _forefoot_supported(metric, baseline, "left") and _forefoot_delta(
        metric, baseline, "left"
    ) >= _forefoot_threshold(
        baseline, "left"
    ):
        return "forefoot_high", "left"
    if _forefoot_supported(metric, baseline, "right") and _forefoot_delta(
        metric, baseline, "right"
    ) >= _forefoot_threshold(
        baseline, "right"
    ):
        return "forefoot_high", "right"

    for side in ("left", "right"):
        for region, risk_type in (
            ("medial", "medial_load_concentration"),
            ("lateral", "lateral_load_concentration"),
        ):
            if _regional_supported(metric, baseline, side, region) and _regional_delta(
                metric, baseline, side, region
            ) >= _regional_threshold(baseline, side, region):
                return risk_type, side

    return None


def _signals(
    metric: PairMetric,
    baseline: BaselineProfile,
) -> list[tuple[str, str]]:
    """Return every independently supported risk in compatibility priority order."""
    result: list[tuple[str, str]] = []
    temperature_side = _temperature_signal_side(metric, baseline)
    if temperature_side is not None:
        result.append(("temperature_asymmetry", temperature_side))
    if metric.motion_state == "moving":
        return result
    if (
        not metric.pressure_valid
        or not baseline.ready
        or not _pressure_supported(metric, baseline)
        or _estimated_total(metric, baseline, "left")
        + _estimated_total(metric, baseline, "right")
        < RISK_MIN_TOTAL_PRESSURE
        or not _pressure_contact_present(metric, baseline)
    ):
        return result
    adjusted_bias = _adjusted_load_bias(metric, baseline)
    if adjusted_bias >= _load_bias_threshold(baseline):
        result.append(("left_load_bias", "left"))
    elif adjusted_bias <= -_load_bias_threshold(baseline):
        result.append(("right_load_bias", "right"))
    for side in ("left", "right"):
        if _forefoot_supported(metric, baseline, side) and _forefoot_delta(
            metric, baseline, side
        ) >= _forefoot_threshold(baseline, side):
            result.append(("forefoot_high", side))
        for region, risk_type in (
            ("medial", "medial_load_concentration"),
            ("lateral", "lateral_load_concentration"),
        ):
            if _regional_supported(metric, baseline, side, region) and _regional_delta(
                metric, baseline, side, region
            ) >= _regional_threshold(baseline, side, region):
                result.append((risk_type, side))
    return result


def _risk_state_for_signal(
    metrics: list[PairMetric],
    baseline: BaselineProfile,
    signal: tuple[str, str],
) -> RiskState | None:
    """Evaluate one signal without allowing another rule to hide it."""
    latest = _pressure_metric_from_window(metrics)
    if signal not in _signals(latest, baseline):
        following = [latest]
        found = False
        next_metric = latest
        for index in range(len(metrics) - 2, -1, -1):
            metric = _pressure_metric_from_window(metrics, index)
            if next_metric.timestamp_ms - metric.timestamp_ms > RISK_CONTINUITY_GAP_MS:
                break
            if signal in _signals(metric, baseline) and all(
                _signal_is_active(item, baseline, signal) for item in following
            ):
                found = True
                break
            following.append(metric)
            next_metric = metric
        if not found:
            return None

    start = latest.timestamp_ms
    next_metric = latest
    for index in range(len(metrics) - 2, -1, -1):
        metric = _pressure_metric_from_window(metrics, index)
        if (
            not _signal_is_active(metric, baseline, signal)
            or (signal[0] != "temperature_asymmetry" and metric.sync_id != latest.sync_id)
            or next_metric.timestamp_ms - metric.timestamp_ms > RISK_CONTINUITY_GAP_MS
        ):
            break
        start = metric.timestamp_ms
        next_metric = metric
    duration = latest.timestamp_ms - start
    attention, warning, persistent = (
        (
            TEMPERATURE_ATTENTION_AFTER_MS,
            TEMPERATURE_WARNING_AFTER_MS,
            TEMPERATURE_PERSISTENT_AFTER_MS,
        )
        if signal[0] == "temperature_asymmetry"
        else (ATTENTION_AFTER_MS, WARNING_AFTER_MS, PERSISTENT_AFTER_MS)
    )
    if duration < attention:
        return None
    level = 1 if duration < warning else 2 if duration < persistent else 3
    return RiskState(
        risk_type=signal[0],
        risk_side=signal[1],
        risk_level=level,
        duration_ms=duration,
    )


def _current_risks(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[list[RiskState], PairMetric]:
    recent_metrics = metrics[-100:]
    latest = _pressure_metric_from_window(recent_metrics)
    candidates = {
        signal
        for index in range(len(recent_metrics))
        for signal in _signals(
            _pressure_metric_from_window(recent_metrics, index), baseline
        )
    }
    risks = [
        state
        for signal in sorted(candidates)
        # Candidate discovery is bounded for responsiveness, but duration is
        # evaluated against the full post-reset history. Using only the last
        # 100 pairs caps a sustained risk at about 19.8 seconds and can make
        # the displayed duration move backwards as the window slides.
        if (state := _risk_state_for_signal(metrics, baseline, signal)) is not None
    ]
    forefoot = {
        item.risk_side: item
        for item in risks
        if item.risk_type == "forefoot_high" and item.risk_side in {"left", "right"}
    }
    if set(forefoot) == {"left", "right"}:
        risks = [item for item in risks if item.risk_type != "forefoot_high"]
        risks.append(
            RiskState(
                risk_type="forefoot_high",
                risk_side="both",
                risk_level=min(forefoot["left"].risk_level, forefoot["right"].risk_level),
                duration_ms=min(
                    forefoot["left"].duration_ms, forefoot["right"].duration_ms
                ),
            )
        )
    risks.sort(
        key=lambda item: (
            -item.risk_level,
            -item.duration_ms,
            item.risk_type,
            item.risk_side,
        )
    )
    return risks, latest


def _signal_is_active(
    metric: PairMetric,
    baseline: BaselineProfile,
    signal: tuple[str, str],
) -> bool:
    """Apply lower exit thresholds so one noisy sample cannot reset a risk."""
    risk_type, risk_side = signal
    if risk_type == "temperature_asymmetry":
        return _temperature_signal_side(metric, baseline, use_exit_threshold=True) == risk_side

    if (
        not metric.pressure_valid
        or not baseline.ready
        or not _pressure_supported(metric, baseline)
        or _estimated_total(metric, baseline, "left")
        + _estimated_total(metric, baseline, "right")
        < RISK_MIN_TOTAL_PRESSURE
        or not _pressure_contact_present(metric, baseline)
    ):
        return False

    if metric.motion_state == "moving":
        return False

    if risk_type == "left_load_bias":
        return _adjusted_load_bias(metric, baseline) >= _load_bias_threshold(
            baseline, exit_threshold=True
        )
    if risk_type == "right_load_bias":
        return _adjusted_load_bias(metric, baseline) <= -_load_bias_threshold(
            baseline, exit_threshold=True
        )
    if risk_type == "forefoot_high":
        if risk_side == "both":
            return all(
                _forefoot_supported(metric, baseline, side)
                and _forefoot_delta(metric, baseline, side)
                >= _forefoot_threshold(baseline, side, exit_threshold=True)
                for side in ("left", "right")
            )
        if not _forefoot_supported(metric, baseline, risk_side):
            return False
        return _forefoot_delta(metric, baseline, risk_side) >= _forefoot_threshold(
            baseline, risk_side, exit_threshold=True
        )
    if risk_type in {
        "medial_load_concentration",
        "lateral_load_concentration",
    }:
        region = "medial" if risk_type.startswith("medial") else "lateral"
        return _regional_supported(metric, baseline, risk_side, region) and _regional_delta(
            metric, baseline, risk_side, region
        ) >= _regional_threshold(
            baseline, risk_side, region, exit_threshold=True
        )
    return False


def _recent_temperature_side(
    metrics: list[PairMetric],
    baseline: BaselineProfile,
) -> str | None:
    """Keep a real temperature episode through a brief ADC/contact dropout."""
    latest_timestamp_ms = metrics[-1].timestamp_ms
    recent_metrics: list[PairMetric] = []
    for metric in reversed(metrics):
        if (
            latest_timestamp_ms - metric.timestamp_ms
            > TEMPERATURE_DROPOUT_GRACE_MS
        ):
            break
        recent_metrics.append(metric)

    for metric in recent_metrics:
        side = _temperature_signal_side(metric, baseline)
        if side is not None:
            return side
    return None


def _current_risk(
    metrics: list[PairMetric], baseline: BaselineProfile
) -> tuple[RiskState, PairMetric]:
    latest = _pressure_metric_from_window(metrics)
    recent_temperature_side = _recent_temperature_side(metrics, baseline)
    latest_signal = _signal(latest, baseline)
    if recent_temperature_side is not None:
        current_signal = ("temperature_asymmetry", recent_temperature_side)
    elif not latest.pressure_valid:
        current_signal = None
    else:
        current_signal = latest_signal

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
                next_metric.timestamp_ms - metric.timestamp_ms
                > RISK_CONTINUITY_GAP_MS
            ):
                break
            candidate = _signal(metric, baseline)
            if (
                candidate is not None
                # Temperature evidence comes from already paired left/right
                # frames and remains continuous across a BLE sync-id rotation.
                and (
                    candidate[0] == "temperature_asymmetry"
                    or metric.sync_id == latest.sync_id
                )
                and all(
                    _signal_is_active(item, baseline, candidate)
                    for item in following
                )
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
    if current_signal[0] == "temperature_asymmetry":
        # Temperature is slow-varying, but a loose NTC/contact can produce one
        # or two low frames. Measure continuity between valid same-side
        # temperature observations and tolerate only a bounded gap.
        newer_evidence_timestamp_ms: int | None = None
        next_metric = latest
        for index in range(len(metrics) - 1, -1, -1):
            metric = _pressure_metric_from_window(metrics, index)
            if (
                next_metric.timestamp_ms - metric.timestamp_ms
                > RISK_CONTINUITY_GAP_MS
            ):
                break
            if _signal_is_active(metric, baseline, current_signal):
                if (
                    newer_evidence_timestamp_ms is not None
                    and newer_evidence_timestamp_ms - metric.timestamp_ms
                    > TEMPERATURE_DROPOUT_GRACE_MS
                ):
                    break
                newer_evidence_timestamp_ms = metric.timestamp_ms
                start = metric.timestamp_ms
            else:
                reference_timestamp_ms = (
                    newer_evidence_timestamp_ms
                    if newer_evidence_timestamp_ms is not None
                    else latest.timestamp_ms
                )
                if (
                    reference_timestamp_ms - metric.timestamp_ms
                    > TEMPERATURE_DROPOUT_GRACE_MS
                ):
                    break
            next_metric = metric
    else:
        next_metric = latest
        for index in range(len(metrics) - 2, -1, -1):
            metric = _pressure_metric_from_window(metrics, index)
            if (
                not _signal_is_active(metric, baseline, current_signal)
                or metric.sync_id != latest.sync_id
                or next_metric.timestamp_ms - metric.timestamp_ms
                > RISK_CONTINUITY_GAP_MS
            ):
                break
            start = metric.timestamp_ms
            next_metric = metric
    duration = latest.timestamp_ms - start
    attention, warning, persistent = (
        (
            TEMPERATURE_ATTENTION_AFTER_MS,
            TEMPERATURE_WARNING_AFTER_MS,
            TEMPERATURE_PERSISTENT_AFTER_MS,
        )
        if current_signal[0] == "temperature_asymmetry"
        else (ATTENTION_AFTER_MS, WARNING_AFTER_MS, PERSISTENT_AFTER_MS)
    )
    if duration < attention:
        level = 0
        risk_type, risk_side, duration = "normal", "none", 0
    elif duration < warning:
        level = 1
        risk_type, risk_side = current_signal
    elif duration < persistent:
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
    metric: PairMetric,
    baseline: BaselineProfile,
    *,
    baseline_trust: tuple[bool, ...] | None = None,
    residual_suspects: tuple[bool, ...] = (False,) * 12,
) -> RegionalAnalysis:
    displayed_sample_count = min(
        baseline.sample_count, BASELINE_MIN_SAMPLES
    )
    if not baseline.ready:
        raw_left = list(metric.left_pressure_valid)
        raw_right = list(metric.right_pressure_valid)
        return RegionalAnalysis(
            baseline_ready=False,
            baseline_source="layout_default",
            baseline_sample_count=displayed_sample_count,
            baseline_required_samples=BASELINE_MIN_SAMPLES,
            pressure_available=metric.pressure_valid,
            left_pressure_valid=raw_left,
            right_pressure_valid=raw_right,
            left_pressure_baseline_trusted=[False] * 6,
            right_pressure_baseline_trusted=[False] * 6,
            left_pressure_analysis_valid=[False] * 6,
            right_pressure_analysis_valid=[False] * 6,
            # During learning, raw-valid points remain available for the
            # heatmap. They are not yet trusted for risk scoring, but calling
            # all of them "uncovered" makes a normal first wearing look like
            # a hardware failure.
            left_pressure_channel_status=[
                "raw_invalid"
                if not valid
                else "residual_suspect"
                if residual_suspects[index]
                else "ok"
                for index, valid in enumerate(raw_left)
            ],
            right_pressure_channel_status=[
                "raw_invalid"
                if not valid
                else "residual_suspect"
                if residual_suspects[6 + index]
                else "ok"
                for index, valid in enumerate(raw_right)
            ],
            temperature_available=any(
                left and right
                for left, right in zip(
                    metric.left_temperature_valid,
                    metric.right_temperature_valid,
                    strict=True,
                )
            ),
            left_temperature_valid=list(metric.left_temperature_valid),
            right_temperature_valid=list(metric.right_temperature_valid),
            left_pressure_scores=[0.0] * 6,
            right_pressure_scores=[0.0] * 6,
            temperature_delta_c=[
                round(value, 2) if value is not None else None
                for value in metric.temperature_delta_c
            ],
            left_temperature_scores=[0.0] * 4,
            right_temperature_scores=[0.0] * 4,
            temperature_offset_status=["unstable"] * 4,
            temperature_offset_channels=[],
            temperature_untrusted_channels=list(range(4)),
            temperature_risk_enabled=False,
            temperature_risk_reason="baseline_not_ready",
        )

    resolved_baseline_trust = baseline_trust or baseline.pressure_channel_trust
    left_scores: list[float] = []
    right_scores: list[float] = []
    left_analysis_valid = [
        metric.left_pressure_valid[index]
        and _runtime_pressure_channel_usable(metric, baseline, "left", index)
        for index in range(6)
    ]
    right_analysis_valid = [
        metric.right_pressure_valid[index]
        and _runtime_pressure_channel_usable(metric, baseline, "right", index)
        for index in range(6)
    ]
    left_distribution = _estimated_distribution(metric, baseline, "left")
    right_distribution = _estimated_distribution(metric, baseline, "right")
    for index in range(6):
        left_trusted = (
            left_analysis_valid[index]
        )
        right_trusted = (
            right_analysis_valid[index]
        )
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
        bilateral_evidence = left_trusted and right_trusted
        left_share_change = (
            left_distribution[index] - baseline.left_distribution[index]
        ) / max(baseline.left_distribution[index], 0.05)
        right_share_change = (
            right_distribution[index] - baseline.right_distribution[index]
        ) / max(baseline.right_distribution[index], 0.05)
        left_scores.append(
            _pressure_score(
                max(
                    left_share_change / REGIONAL_SHARE_DELTA_FOR_SEVERE,
                    corrected_asymmetry / REGIONAL_ASYMMETRY_FOR_SEVERE
                    if bilateral_evidence
                    else 0.0,
                )
            ) if left_trusted else 0.0
        )
        right_scores.append(
            _pressure_score(
                max(
                    right_share_change / REGIONAL_SHARE_DELTA_FOR_SEVERE,
                    -corrected_asymmetry / REGIONAL_ASYMMETRY_FOR_SEVERE
                    if bilateral_evidence
                    else 0.0,
                )
            ) if right_trusted else 0.0
        )

    corrected_temperature = [
        round(value - baseline.temperature_delta_c[index], 2)
        if value is not None and baseline.temperature_valid[index]
        else None
        for index, value in enumerate(metric.temperature_delta_c)
    ]
    temperature_status = list(baseline.temperature_offset_status)
    temperature_valid_count = sum(
        value is not None
        and metric.left_temperature_valid[index]
        and metric.right_temperature_valid[index]
        and temperature_status[index] not in {"raw_invalid", "unstable"}
        for index, value in enumerate(metric.temperature_delta_c)
    )
    offset_channels = [
        index for index, status in enumerate(temperature_status)
        if status == "assembly_offset"
    ]
    untrusted_channels = [
        index for index, status in enumerate(temperature_status)
        if status in {"raw_invalid", "unstable"}
    ]
    return RegionalAnalysis(
        baseline_ready=baseline.ready,
        baseline_source="personal" if baseline.ready else "layout_default",
        baseline_sample_count=displayed_sample_count,
        baseline_required_samples=BASELINE_MIN_SAMPLES,
        pressure_available=(
            metric.pressure_valid
            and _pressure_supported(metric, baseline)
            and _pressure_contact_present(metric, baseline)
        ),
        left_pressure_valid=list(metric.left_pressure_valid),
        right_pressure_valid=list(metric.right_pressure_valid),
        left_pressure_baseline_trusted=list(resolved_baseline_trust[:6]),
        right_pressure_baseline_trusted=list(resolved_baseline_trust[6:]),
        left_pressure_analysis_valid=left_analysis_valid,
        right_pressure_analysis_valid=right_analysis_valid,
        left_pressure_channel_status=[
            "raw_invalid"
            if not metric.left_pressure_valid[index]
            else "residual_suspect"
            if residual_suspects[index]
            else "runtime_recovered"
            if left_analysis_valid[index] and not resolved_baseline_trust[index]
            else "uncovered_in_baseline"
            if not resolved_baseline_trust[index]
            else "ok"
            for index in range(6)
        ],
        right_pressure_channel_status=[
            "raw_invalid"
            if not metric.right_pressure_valid[index]
            else "residual_suspect"
            if residual_suspects[6 + index]
            else "runtime_recovered"
            if right_analysis_valid[index] and not resolved_baseline_trust[6 + index]
            else "uncovered_in_baseline"
            if not resolved_baseline_trust[6 + index]
            else "ok"
            for index in range(6)
        ],
        temperature_available=any(
            value is not None for value in metric.temperature_delta_c
        ),
        left_temperature_valid=list(metric.left_temperature_valid),
        right_temperature_valid=list(metric.right_temperature_valid),
        left_pressure_scores=left_scores,
        right_pressure_scores=right_scores,
        temperature_delta_c=corrected_temperature,
        left_temperature_scores=[
            _clamp_score(value / TEMPERATURE_DELTA_C_THRESHOLD)
            if value is not None
            else 0.0
            for value in corrected_temperature
        ],
        right_temperature_scores=[
            _clamp_score(-value / TEMPERATURE_DELTA_C_THRESHOLD)
            if value is not None
            else 0.0
            for value in corrected_temperature
        ],
        temperature_offset_status=temperature_status,
        temperature_offset_channels=offset_channels,
        temperature_untrusted_channels=untrusted_channels,
        temperature_risk_enabled=temperature_valid_count >= 2,
        temperature_risk_reason=(
            "ready"
            if temperature_valid_count >= 2
            else "fewer_than_two_trusted_channels"
        ),
    )


def _calibration_reason(
    metrics: list[PairMetric],
    baseline: BaselineProfile,
    residual_suspects: tuple[bool, ...] = (False,) * 12,
) -> str:
    if baseline.ready:
        return "ready"
    if not metrics:
        return "waiting_for_data"
    if (
        not metrics[-1].pressure_valid
        or not all(metrics[-1].left_pressure_valid)
        or not all(metrics[-1].right_pressure_valid)
    ):
        return "pressure_unavailable"
    latest = metrics[-1]
    left_active = sum(
        latest.left_pressure_valid[index]
        and not residual_suspects[index]
        and latest.left_pressure[index] >= BASELINE_ACTIVE_PRESSURE_FLOOR
        for index in range(6)
    )
    right_active = sum(
        latest.right_pressure_valid[index]
        and not residual_suspects[6 + index]
        and latest.right_pressure[index] >= BASELINE_ACTIVE_PRESSURE_FLOOR
        for index in range(6)
    )
    left_loaded = (
        sum(
            value
            for index, value in enumerate(latest.left_pressure)
            if not residual_suspects[index]
        )
        >= BASELINE_MIN_FOOT_PRESSURE
        and left_active >= BASELINE_MIN_ACTIVE_CHANNELS
    )
    right_loaded = (
        sum(
            value
            for index, value in enumerate(latest.right_pressure)
            if not residual_suspects[6 + index]
        )
        >= BASELINE_MIN_FOOT_PRESSURE
        and right_active >= BASELINE_MIN_ACTIVE_CHANNELS
    )
    if not left_loaded and right_loaded:
        return "left_not_loaded"
    if left_loaded and not right_loaded:
        return "right_not_loaded"
    if not left_loaded and not right_loaded:
        return "pressure_residual" if any(residual_suspects) else "not_loaded"
    if metrics[-1].motion_state == "moving":
        return "moving"
    return "unstable"


def calibration_status(session: Session) -> CalibrationStatus:
    left_latest = latest_frame(session, "left")
    right_latest = latest_frame(session, "right")
    latest_pair = _latest_complete_pair(session, left_latest, right_latest)
    if latest_pair is None:
        metrics: list[PairMetric] = []
        resolved = _empty_baseline()
    else:
        left_model, right_model = latest_pair
        metrics = _pair_history(session, left_model, right_model)
        resolved = _saved_baseline(session, left_model, right_model) or _baseline_profile(
            metrics
        )
    residual_suspects = (
        (False,) * 12
        if resolved.ready
        else _prebaseline_residual_suspect_channels(metrics)
    )
    state = calibration_state(session)
    _, _, _, empty_status = _empty_temperature_reference(metrics)
    temperature_status = (
        resolved.temperature_offset_status
        if resolved.ready
        else empty_status if metrics else ("unstable",) * 4
    )
    temperature_valid_count = sum(
        status not in {"raw_invalid", "unstable"}
        for status in temperature_status
    )
    temperature_enabled = resolved.ready and temperature_valid_count >= 2
    return CalibrationStatus(
        baseline_ready=resolved.ready,
        sample_count=min(resolved.sample_count, BASELINE_MIN_SAMPLES),
        required_samples=BASELINE_MIN_SAMPLES,
        reset_at_ms=state.reset_at_ms if state is not None else None,
        status_reason=_calibration_reason(metrics, resolved, residual_suspects),
        empty_temperature_reference_ready=bool(metrics) and any(
            status not in {"raw_invalid", "unstable"} for status in empty_status
        ),
        temperature_risk_enabled=temperature_enabled,
        temperature_offset_channels=[
            index for index, status in enumerate(temperature_status)
            if status == "assembly_offset"
        ],
        temperature_untrusted_channels=[
            index for index, status in enumerate(temperature_status)
            if status in {"raw_invalid", "unstable"}
        ],
        temperature_risk_reason=(
            "ready"
            if temperature_enabled
            else "temperature_unstable"
            if resolved.ready
            else "baseline_not_ready"
        ),
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
        status_reason="waiting_for_data",
        empty_temperature_reference_ready=False,
        temperature_risk_enabled=False,
        temperature_offset_channels=[],
        temperature_untrusted_channels=list(range(4)),
        temperature_risk_reason="baseline_not_ready",
    )


def _recovery_label(before: float, after: float) -> str:
    improvement = (before - after) / max(before, 1e-9)
    if improvement < 0:
        return "worsened"
    if improvement >= RECOVERY_EFFECTIVE_RATIO:
        return "effective"
    if improvement >= RECOVERY_PARTIAL_RATIO:
        return "partial"
    return "ineffective"


def _risk_difference(
    metric: PairMetric,
    baseline: BaselineProfile | None,
    risk_type: str,
    risk_side: str,
) -> float:
    if baseline is None:
        return metric.load_diff
    if risk_type in {"left_load_bias", "right_load_bias"}:
        return abs(_adjusted_load_bias(metric, baseline))
    if risk_type == "forefoot_high":
        if risk_side == "both":
            return max(
                0.0,
                _forefoot_delta(metric, baseline, "left"),
                _forefoot_delta(metric, baseline, "right"),
            )
        return max(0.0, _forefoot_delta(metric, baseline, risk_side))
    if risk_type in {
        "medial_load_concentration",
        "lateral_load_concentration",
    }:
        region = "medial" if risk_type.startswith("medial") else "lateral"
        return max(0.0, _regional_delta(metric, baseline, risk_side, region))
    if risk_type == "temperature_asymmetry":
        corrected = _temperature_delta_from_baseline(metric, baseline)
        return max((abs(value) for value in corrected if value is not None), default=0.0)
    return metric.load_diff


def _risk_metric_available(metric: PairMetric, risk_type: str) -> bool:
    if risk_type == "temperature_asymmetry":
        return _temperature_pair_count(metric) >= 2
    return metric.pressure_valid


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


def _refresh_recovery_feedback(
    session: Session,
    metric: PairMetric,
    baseline: BaselineProfile | None,
) -> None:
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
    if not _risk_metric_available(metric, event.risk_type):
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
    after_difference = _risk_difference(
        metric, baseline, event.risk_type, event.risk_side
    )
    label = _recovery_label(event.before_load_diff, after_difference)
    if feedback is None:
        feedback = InterventionFeedback(
            event_id=event.event_id,
            user_action="motor_vibration",
            effect_label=label,
            before_load_diff=event.before_load_diff,
            after_load_diff=after_difference,
            recovery_time_ms=max(0, metric.timestamp_ms - event.started_at_ms),
            created_at_ms=int(time() * 1000),
        )
        session.add(feedback)
    else:
        feedback.effect_label = label
        feedback.after_load_diff = after_difference
        feedback.recovery_time_ms = max(0, metric.timestamp_ms - event.started_at_ms)
    # Keep the event values and the feedback label on the same observation.
    # The history API otherwise combines a stale event.after_load_diff with a
    # freshly updated feedback.effect_label and can display contradictions.
    event.after_load_diff = after_difference
    session.commit()


def _record_risk(
    session: Session,
    risk: RiskState,
    metric: PairMetric | None,
    *,
    allow_motor_command: bool,
    baseline: BaselineProfile | None = None,
) -> None:
    event = active_event(session)
    if risk.risk_type in {"normal", "data_incomplete"}:
        if event is not None:
            timestamp = metric.timestamp_ms if metric else event.started_at_ms + event.duration_ms
            metric_available = (
                metric is not None
                and _risk_metric_available(metric, event.risk_type)
            )
            resolved = risk.risk_type == "normal" and metric_available
            _close_event(
                session,
                event,
                timestamp,
                _risk_difference(
                    metric, baseline, event.risk_type, event.risk_side
                )
                if metric
                else None,
                "resolved" if resolved else "interrupted",
            )
        if risk.risk_type == "normal" and metric is not None:
            _refresh_recovery_feedback(session, metric, baseline)
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
        > event.started_at_ms + RISK_CONTINUITY_GAP_MS
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
        _close_event(
            session,
            event,
            metric.timestamp_ms,
            _risk_difference(metric, baseline, event.risk_type, event.risk_side),
            "resolved",
        )
        event = None
    risk_difference = _risk_difference(
        metric, baseline, risk.risk_type, risk.risk_side
    )
    if event is None:
        event = RiskEvent(
            event_id=f"evt_{metric.timestamp_ms}_{risk.risk_side}",
            risk_type=risk.risk_type,
            risk_side=risk.risk_side,
            risk_level=risk.risk_level,
            started_at_ms=candidate_started_at_ms,
            ended_at_ms=None,
            duration_ms=risk.duration_ms,
            before_load_diff=risk_difference,
            after_load_diff=None,
            status="active",
        )
        session.add(event)
    else:
        event.risk_level = risk.risk_level
        event.duration_ms = risk.duration_ms
        event.after_load_diff = risk_difference
    session.commit()
    if allow_motor_command:
        ensure_motor_command(session, event, risk.risk_level)


def _combined_side(risks: list[RiskState]) -> str:
    if any(risk.risk_side == "both" for risk in risks):
        return "both"
    sides = {risk.risk_side for risk in risks if risk.risk_side in {"left", "right"}}
    if sides == {"left", "right"}:
        return "both"
    return next(iter(sides), "none")


def _record_combined_risks(
    session: Session,
    risks: list[RiskState],
    metric: PairMetric | None,
    *,
    allow_motor_command: bool,
    baseline: BaselineProfile | None,
    fallback_risk: RiskState,
) -> None:
    event = active_event(session)
    if not risks:
        if event is not None and metric is not None:
            last_observed = event.started_at_ms + event.duration_ms
            if metric.timestamp_ms - last_observed < RISK_EVENT_CLEAR_HOLD_MS:
                return
        _record_risk(
            session,
            RiskState(
                risk_type="normal",
                risk_side="none",
                risk_level=0,
                duration_ms=0,
            ),
            metric,
            allow_motor_command=False,
            baseline=baseline,
        )
        return
    if metric is None:
        return
    primary = risks[0]
    candidate_start = min(metric.timestamp_ms - risk.duration_ms for risk in risks)
    if event is not None:
        last_observed = event.started_at_ms + event.duration_ms
        if metric.timestamp_ms - last_observed > RISK_CONTINUITY_GAP_MS:
            _close_event(
                session,
                event,
                last_observed,
                event.after_load_diff,
                "interrupted",
            )
            event = None
    primary_difference = _risk_difference(
        metric, baseline, primary.risk_type, primary.risk_side
    )
    previous_components: dict[tuple[str, str], dict[str, object]] = {}
    if event is not None:
        try:
            stored = json.loads(event.risk_components_json or "[]")
            if isinstance(stored, list):
                previous_components = {
                    (item["risk_type"], item["risk_side"]): item
                    for item in stored
                    if isinstance(item, dict)
                    and "risk_type" in item
                    and "risk_side" in item
                }
        except (TypeError, ValueError):
            previous_components = {}
    for risk in risks:
        key = (risk.risk_type, risk.risk_side)
        previous = previous_components.get(key, {})
        previous_components[key] = {
            **risk.model_dump(),
            "risk_level": max(int(previous.get("risk_level", 0)), risk.risk_level),
            "duration_ms": max(int(previous.get("duration_ms", 0)), risk.duration_ms),
        }
    components_json = json.dumps(
        list(previous_components.values()),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    if event is None:
        event = RiskEvent(
            event_id=f"evt_{metric.timestamp_ms}_combined",
            risk_type=primary.risk_type,
            risk_side=_combined_side(risks),
            risk_level=max(risk.risk_level for risk in risks),
            started_at_ms=candidate_start,
            ended_at_ms=None,
            duration_ms=metric.timestamp_ms - candidate_start,
            before_load_diff=primary_difference,
            after_load_diff=None,
            status="active",
            risk_components_json=components_json,
        )
        session.add(event)
    else:
        event.risk_type = primary.risk_type
        event.risk_side = _combined_side(risks)
        event.risk_level = max(risk.risk_level for risk in risks)
        event.duration_ms = max(0, metric.timestamp_ms - event.started_at_ms)
        event.after_load_diff = primary_difference
        event.risk_components_json = components_json
    session.commit()
    if allow_motor_command:
        motor_risks = [
            risk
            for risk in risks
            if risk.risk_type == "temperature_asymmetry"
            or metric.motion_state != "moving"
        ]
        ensure_combined_motor_command(session, event, motor_risks)


def evaluate_risk(
    session: Session,
    *,
    record: bool = False,
    allow_motor_command: bool = True,
) -> RealtimeResponse:
    from .session_service import recovery_observation
    left_latest = latest_frame(session, "left")
    right_latest = latest_frame(session, "right")
    latest_pair = _latest_complete_pair(session, left_latest, right_latest)
    if latest_pair is None:
        risk = RiskState(
            risk_type="data_incomplete", risk_side="none", risk_level=0, duration_ms=0
        )
        if record:
            _record_risk(
                session,
                risk,
                None,
                allow_motor_command=allow_motor_command,
            )
        return RealtimeResponse(
            left=to_schema(left_latest) if left_latest else None,
            right=to_schema(right_latest) if right_latest else None,
            paired_timestamp_ms=None,
            sync_error_ms=None,
            load_bias=None,
            load_diff=None,
            motion_state="unavailable",
            left_motion_state="unavailable",
            right_motion_state="unavailable",
            pressure_available=False,
            temperature_available=False,
            risk=risk,
            active_risks=[],
            regional_analysis=None,
            recovery_observation=recovery_observation(session),
        )
    left_model, right_model = latest_pair
    left = to_schema(left_model)
    right = to_schema(right_model)
    metrics = _pair_history(session, left_model, right_model)
    learned_baseline = _saved_baseline(session, left_model, right_model)
    if learned_baseline is None:
        candidate_baseline = _baseline_profile(metrics)
        if candidate_baseline.ready:
            save_calibration_profile(
                session,
                _profile_to_model(candidate_baseline, left_model, right_model),
            )
        baseline = candidate_baseline
    else:
        baseline = learned_baseline
        if not any(
            status not in {"unstable", "raw_invalid"}
            for status in learned_baseline.temperature_offset_status
        ):
            temperature_candidate = _baseline_profile(metrics)
            if temperature_candidate.ready and any(
                status not in {"unstable", "raw_invalid"}
                for status in temperature_candidate.temperature_offset_status
            ):
                baseline = replace(
                    learned_baseline,
                    temperature_delta_c=temperature_candidate.temperature_delta_c,
                    temperature_valid=temperature_candidate.temperature_valid,
                    empty_temperature_delta_c=(
                        temperature_candidate.empty_temperature_delta_c
                    ),
                    empty_temperature_mad_c=(
                        temperature_candidate.empty_temperature_mad_c
                    ),
                    empty_temperature_slope_c_per_s=(
                        temperature_candidate.empty_temperature_slope_c_per_s
                    ),
                    temperature_offset_status=(
                        temperature_candidate.temperature_offset_status
                    ),
                    wearing_temperature_mad_c=(
                        temperature_candidate.wearing_temperature_mad_c
                    ),
                )
                save_calibration_profile(
                    session,
                    _profile_to_model(baseline, left_model, right_model),
                )
    risk_metrics = metrics or [_metric(left_model, right_model)]
    baseline_trust = baseline.pressure_channel_trust
    analysis_baseline, residual_suspects = _diagnosed_baseline(
        risk_metrics, baseline
    )
    active_risks, metric = _current_risks(risk_metrics, analysis_baseline)
    risk, _ = _current_risk(risk_metrics[-100:], analysis_baseline)
    gait = _gait_summary(
        risk_metrics,
        analysis_baseline,
        session=session,
        record=record,
    )
    if active_risks:
        risk = active_risks[0]
    if record:
        actionable_risks = [item for item in active_risks if item.risk_level >= 2]
        _record_combined_risks(
            session,
            actionable_risks,
            metric,
            allow_motor_command=(
                allow_motor_command
                and (
                    any(
                        item.risk_type == "temperature_asymmetry"
                        for item in active_risks
                    )
                    or (
                        analysis_baseline.ready
                        and metric.pressure_valid
                        and metric.motion_state != "moving"
                    )
                )
            ),
            baseline=analysis_baseline,
            fallback_risk=risk,
        )
    return RealtimeResponse(
        left=left,
        right=right,
        paired_timestamp_ms=metric.timestamp_ms,
        sync_error_ms=abs(left.timestamp_ms - right.timestamp_ms),
        load_bias=metric.load_bias,
        load_diff=metric.load_diff,
        motion_state=metric.motion_state,
        left_motion_state=metric.left_motion_state,
        right_motion_state=metric.right_motion_state,
        gait=gait,
        pressure_available=(
            metric.pressure_valid
            and _pressure_supported(metric, analysis_baseline)
            and _pressure_contact_present(metric, analysis_baseline)
        ),
        temperature_available=any(
            value is not None for value in metric.temperature_delta_c
        ),
        risk=risk,
        active_risks=active_risks,
        regional_analysis=_regional_analysis(
            metric,
            analysis_baseline,
            baseline_trust=baseline_trust,
            residual_suspects=residual_suspects,
        ),
        recovery_observation=recovery_observation(session),
    )
