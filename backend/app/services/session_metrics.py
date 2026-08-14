from __future__ import annotations

from math import log

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import SensorFrame
from ..schemas import RiskComponentFeedback, RiskState


def _nearest_frame(
    session: Session, side: str, timestamp_ms: int
) -> SensorFrame | None:
    after = session.scalar(
        select(SensorFrame)
        .where(SensorFrame.side == side, SensorFrame.timestamp_ms >= timestamp_ms)
        .order_by(SensorFrame.timestamp_ms)
        .limit(1)
    )
    before = session.scalar(
        select(SensorFrame)
        .where(SensorFrame.side == side, SensorFrame.timestamp_ms < timestamp_ms)
        .order_by(SensorFrame.timestamp_ms.desc())
        .limit(1)
    )
    candidates = [item for item in (after, before) if item is not None]
    if not candidates:
        return None
    result = min(candidates, key=lambda item: abs(item.timestamp_ms - timestamp_ms))
    return result if abs(result.timestamp_ms - timestamp_ms) <= 2_000 else None


def _sensor_snapshot(
    session: Session, timestamp_ms: int
) -> dict[str, float] | None:
    left = _nearest_frame(session, "left", timestamp_ms)
    right = _nearest_frame(session, "right", timestamp_ms)
    if left is None or right is None:
        return None
    left_pressure = [left.p1, left.p2, left.p3, left.p4, left.p5, left.p6]
    right_pressure = [right.p1, right.p2, right.p3, right.p4, right.p5, right.p6]
    left_total = sum(left_pressure)
    right_total = sum(right_pressure)
    left_forefoot = sum(left_pressure[:4])
    right_forefoot = sum(right_pressure[:4])
    return {
        "load_ratio_abs": abs(log((left_total + 1e-6) / (right_total + 1e-6))),
        "left_forefoot_ratio": left_forefoot / max(left_total, 1e-6),
        "right_forefoot_ratio": right_forefoot / max(right_total, 1e-6),
        "left_medial_ratio": (left_pressure[0] + left_pressure[3]) / max(left_forefoot, 1e-6),
        "right_medial_ratio": (right_pressure[0] + right_pressure[3]) / max(right_forefoot, 1e-6),
        "left_lateral_ratio": left_pressure[1] / max(left_forefoot, 1e-6),
        "right_lateral_ratio": right_pressure[1] / max(right_forefoot, 1e-6),
        "temperature_delta_max_c": max(
            abs(a - b)
            for a, b in zip(
                [left.t1, left.t2, left.t3, left.t4],
                [right.t1, right.t2, right.t3, right.t4],
                strict=True,
            )
        ),
    }


def component_feedback(
    session: Session,
    components: list[RiskState],
    intervention_started_at_ms: int | None,
) -> list[RiskComponentFeedback]:
    if intervention_started_at_ms is None:
        return []
    before = _sensor_snapshot(session, intervention_started_at_ms)
    after = _sensor_snapshot(session, intervention_started_at_ms + 15_000)
    result: list[RiskComponentFeedback] = []
    for component in components:
        pressure_intervention = component.risk_type != "temperature_asymmetry"
        key = (
            "load_ratio_abs"
            if component.risk_type in {"left_load_bias", "right_load_bias"}
            else f"{component.risk_side}_forefoot_ratio"
            if component.risk_type == "forefoot_high" and component.risk_side != "both"
            else "forefoot_both_ratio"
            if component.risk_type == "forefoot_high"
            else f"{component.risk_side}_medial_ratio"
            if component.risk_type == "medial_load_concentration"
            else f"{component.risk_side}_lateral_ratio"
            if component.risk_type == "lateral_load_concentration"
            else "temperature_delta_max_c"
        )
        before_value = before.get(key) if before else None
        after_value = after.get(key) if after else None
        if key == "forefoot_both_ratio":
            before_value = max(
                before.get("left_forefoot_ratio", 0.0),
                before.get("right_forefoot_ratio", 0.0),
            ) if before else None
            after_value = max(
                after.get("left_forefoot_ratio", 0.0),
                after.get("right_forefoot_ratio", 0.0),
            ) if after else None
        improvement = (
            (before_value - after_value) / before_value
            if pressure_intervention
            and before_value is not None
            and after_value is not None
            and before_value > 1e-9
            else None
        )
        effect = (
            "observation_only"
            if not pressure_intervention
            else "unknown"
            if improvement is None
            else "effective"
            if improvement >= 0.5
            else "partial"
            if improvement >= 0.2
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
                metric_unit="celsius" if component.risk_type == "temperature_asymmetry" else "ratio",
            )
        )
    return result
