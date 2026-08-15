from __future__ import annotations

import json
from collections import defaultdict
from math import log, sqrt, tanh
from statistics import median

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import (
    CALIBRATION_INVALID_MASK,
    IMU_ACCEL_STATIONARY_TOLERANCE_MS2,
    IMU_GRAVITY_MS2,
    IMU_GYRO_STATIONARY_THRESHOLD_DPS,
    IMU_INVALID_MASK,
    PRESSURE_MIN_VALID_CHANNELS_PER_FOOT,
    RECOVERY_AFTER_WINDOW_MS,
    RECOVERY_BEFORE_WINDOW_MS,
    RECOVERY_EFFECTIVE_RATIO,
    RECOVERY_MIN_VALID_PAIRS,
    RECOVERY_OBSERVATION_MS,
    RECOVERY_PARTIAL_RATIO,
)
from ..models import CalibrationProfile, SensorFrame
from ..repositories.calibration_repository import calibration_profile
from ..schemas import RiskComponentFeedback, RiskImprovementSummary, RiskState


def _pressure(frame: SensorFrame) -> tuple[float, ...]:
    return (frame.p1, frame.p2, frame.p3, frame.p4, frame.p5, frame.p6)


def _stationary(frame: SensorFrame) -> bool:
    if frame.quality_flags & IMU_INVALID_MASK:
        return False
    acceleration = sqrt(frame.ax * frame.ax + frame.ay * frame.ay + frame.az * frame.az)
    gyro = sqrt(frame.gx * frame.gx + frame.gy * frame.gy + frame.gz * frame.gz)
    return (
        abs(acceleration - IMU_GRAVITY_MS2)
        <= IMU_ACCEL_STATIONARY_TOLERANCE_MS2
        and gyro <= IMU_GYRO_STATIONARY_THRESHOLD_DPS
    )


def _profile_values(
    profile: CalibrationProfile,
) -> tuple[tuple[float, ...], tuple[float, ...], tuple[bool, ...]]:
    left = tuple(float(value) for value in json.loads(profile.left_distribution_json))
    right = tuple(float(value) for value in json.loads(profile.right_distribution_json))
    trust = tuple(bool(value) for value in json.loads(profile.pressure_channel_trust_json))
    if len(trust) == 6:
        trust = trust * 2
    return left, right, trust


def _estimated_distribution(
    pressure: tuple[float, ...],
    reference: tuple[float, ...],
    trust: tuple[bool, ...],
) -> tuple[float, ...] | None:
    trusted_reference = sum(reference[index] for index in range(6) if trust[index])
    trusted_pressure = sum(pressure[index] for index in range(6) if trust[index])
    if trusted_reference <= 1e-9 or trusted_pressure <= 1e-9:
        return None
    estimated_total = trusted_pressure / trusted_reference
    return tuple(
        pressure[index] / estimated_total if trust[index] else reference[index]
        for index in range(6)
    )


def _estimated_total(
    pressure: tuple[float, ...],
    reference: tuple[float, ...],
    trust: tuple[bool, ...],
) -> float | None:
    reference_share = sum(reference[index] for index in range(6) if trust[index])
    observed = sum(pressure[index] for index in range(6) if trust[index])
    if reference_share <= 1e-9 or observed <= 1e-9:
        return None
    return observed / reference_share


def _paired_window(
    session: Session,
    start_ms: int,
    end_ms: int,
    profile: CalibrationProfile,
) -> list[tuple[SensorFrame, SensorFrame]]:
    rows = list(
        session.scalars(
            select(SensorFrame)
            .where(
                SensorFrame.timestamp_ms >= start_ms,
                SensorFrame.timestamp_ms <= end_ms,
            )
            .order_by(SensorFrame.timestamp_ms)
        )
    )
    grouped: dict[tuple[int, int], dict[str, SensorFrame]] = defaultdict(dict)
    for row in rows:
        if row.side == "left" and row.device_id != profile.left_device_id:
            continue
        if row.side == "right" and row.device_id != profile.right_device_id:
            continue
        grouped[(row.sync_id, row.packet_seq)][row.side] = row
    result: list[tuple[SensorFrame, SensorFrame]] = []
    for pair in grouped.values():
        left, right = pair.get("left"), pair.get("right")
        if left is None or right is None:
            continue
        if (
            left.quality_flags & CALIBRATION_INVALID_MASK
            or right.quality_flags & CALIBRATION_INVALID_MASK
        ):
            continue
        if not _stationary(left) or not _stationary(right):
            continue
        result.append((left, right))
    return result


def _pair_metrics(
    left: SensorFrame,
    right: SensorFrame,
    profile: CalibrationProfile,
    baseline_left: tuple[float, ...],
    baseline_right: tuple[float, ...],
    trust: tuple[bool, ...],
) -> dict[str, float]:
    left_pressure, right_pressure = _pressure(left), _pressure(right)
    left_trust = tuple(
        trust[index] and not left.quality_flags & (1 << index)
        for index in range(6)
    )
    right_trust = tuple(
        trust[6 + index] and not right.quality_flags & (1 << index)
        for index in range(6)
    )
    if (
        sum(left_trust) < PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
        or sum(right_trust) < PRESSURE_MIN_VALID_CHANNELS_PER_FOOT
    ):
        return {}
    left_total = _estimated_total(left_pressure, baseline_left, left_trust)
    right_total = _estimated_total(right_pressure, baseline_right, right_trust)
    left_distribution = _estimated_distribution(left_pressure, baseline_left, left_trust)
    right_distribution = _estimated_distribution(right_pressure, baseline_right, right_trust)
    result: dict[str, float] = {}
    if left_total is not None and right_total is not None:
        residual = log((left_total + 1e-6) / (right_total + 1e-6)) - profile.load_ratio
        result["load_asymmetry_excess"] = abs(tanh(residual / 2.0))

    def add_side_metrics(
        side: str,
        distribution: tuple[float, ...] | None,
        baseline: tuple[float, ...],
        side_trust: tuple[bool, ...],
    ) -> None:
        if distribution is None:
            return
        trusted_forefoot = sum(side_trust[index] for index in range(4))
        trusted_rearfoot = sum(side_trust[index] for index in range(4, 6))
        if trusted_forefoot >= 2 and trusted_rearfoot >= 1:
            result[f"{side}_forefoot_excess"] = max(
                0.0,
                sum(distribution[:4]) - sum(baseline[:4]),
            )
        current_forefoot = sum(distribution[:4])
        baseline_forefoot = sum(baseline[:4])
        if trusted_forefoot < 2 or current_forefoot <= 1e-9 or baseline_forefoot <= 1e-9:
            return
        for region, indices in (("medial", (0, 3)), ("lateral", (1,))):
            if not any(side_trust[index] for index in indices):
                continue
            current_share = sum(distribution[index] for index in indices) / current_forefoot
            baseline_share = sum(baseline[index] for index in indices) / baseline_forefoot
            result[f"{side}_{region}_excess"] = max(0.0, current_share - baseline_share)

    add_side_metrics("left", left_distribution, baseline_left, left_trust)
    add_side_metrics("right", right_distribution, baseline_right, right_trust)
    return result


def _window_metrics(
    session: Session,
    start_ms: int,
    end_ms: int,
    profile: CalibrationProfile,
) -> list[dict[str, float]]:
    baseline_left, baseline_right, trust = _profile_values(profile)
    return [
        _pair_metrics(left, right, profile, baseline_left, baseline_right, trust)
        for left, right in _paired_window(session, start_ms, end_ms, profile)
    ]


def _metric_key(component: RiskState) -> tuple[str, str]:
    if component.risk_type in {"left_load_bias", "right_load_bias"}:
        return "load_asymmetry_excess", "ratio"
    region = {
        "forefoot_high": "forefoot",
        "medial_load_concentration": "medial",
        "lateral_load_concentration": "lateral",
    }.get(component.risk_type)
    if region is None:
        return "temperature_delta_max_c", "celsius"
    if component.risk_side == "both":
        return f"both_{region}_excess", "percentage_point"
    return f"{component.risk_side}_{region}_excess", "percentage_point"


def _window_value(samples: list[dict[str, float]], key: str) -> float | None:
    if key.startswith("both_"):
        region = key.removeprefix("both_")
        values = [
            max(sample.get(f"left_{region}", 0.0), sample.get(f"right_{region}", 0.0))
            for sample in samples
            if f"left_{region}" in sample and f"right_{region}" in sample
        ]
    else:
        values = [sample[key] for sample in samples if key in sample]
    return median(values) if len(values) >= RECOVERY_MIN_VALID_PAIRS else None


def component_feedback(
    session: Session,
    components: list[RiskState],
    intervention_started_at_ms: int | None,
) -> list[RiskComponentFeedback]:
    if intervention_started_at_ms is None:
        return []
    profile = calibration_profile(session)
    before_samples: list[dict[str, float]] = []
    after_samples: list[dict[str, float]] = []
    if profile is not None:
        before_samples = _window_metrics(
            session,
            intervention_started_at_ms - RECOVERY_BEFORE_WINDOW_MS,
            intervention_started_at_ms,
            profile,
        )
        deadline = intervention_started_at_ms + RECOVERY_OBSERVATION_MS
        after_samples = _window_metrics(
            session,
            deadline - RECOVERY_AFTER_WINDOW_MS,
            deadline,
            profile,
        )

    result: list[RiskComponentFeedback] = []
    for component in components:
        pressure_intervention = component.risk_type != "temperature_asymmetry"
        key, unit = _metric_key(component)
        before_value = _window_value(before_samples, key) if pressure_intervention else None
        after_value = _window_value(after_samples, key) if pressure_intervention else None
        improvement = (
            (before_value - after_value) / before_value
            if before_value is not None
            and after_value is not None
            and before_value > 1e-9
            else None
        )
        effect = (
            "observation_only"
            if not pressure_intervention
            else "unknown"
            if improvement is None
            else "worsened"
            if improvement < 0
            else "effective"
            if improvement >= RECOVERY_EFFECTIVE_RATIO
            else "partial"
            if improvement >= RECOVERY_PARTIAL_RATIO
            else "ineffective"
        )
        result.append(
            RiskComponentFeedback(
                risk_type=component.risk_type,
                risk_side=component.risk_side,
                before_value=before_value,
                after_value=after_value,
                improvement_ratio=improvement,
                effect_label=effect,
                pressure_intervention=pressure_intervention,
                metric_code=key,
                metric_unit=unit,
            )
        )
    return result


def summarize_improvements(
    feedback: list[RiskComponentFeedback],
) -> list[RiskImprovementSummary]:
    grouped: dict[tuple[str, str], list[RiskComponentFeedback]] = defaultdict(list)
    for item in feedback:
        if item.pressure_intervention:
            grouped[(item.risk_type, item.risk_side)].append(item)
    result: list[RiskImprovementSummary] = []
    for (risk_type, risk_side), items in sorted(grouped.items()):
        ratios = [item.improvement_ratio for item in items if item.improvement_ratio is not None]
        before = [item.before_value for item in items if item.before_value is not None]
        after = [item.after_value for item in items if item.after_value is not None]
        result.append(
            RiskImprovementSummary(
                risk_type=risk_type,
                risk_side=risk_side,
                evaluated_count=len(ratios),
                effective_count=sum(item.effect_label == "effective" for item in items),
                partial_count=sum(item.effect_label == "partial" for item in items),
                ineffective_count=sum(item.effect_label == "ineffective" for item in items),
                worsened_count=sum(item.effect_label == "worsened" for item in items),
                data_insufficient_count=sum(item.effect_label == "unknown" for item in items),
                median_improvement_ratio=median(ratios) if ratios else None,
                before_median=median(before) if before else None,
                after_median=median(after) if after else None,
                metric_unit=next((item.metric_unit for item in items if item.metric_unit), None),
            )
        )
    return result
