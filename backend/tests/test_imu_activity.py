from __future__ import annotations

from types import SimpleNamespace

import pytest

from backend.app.config import (
    ATTENTION_AFTER_MS,
    MOVING_PRESSURE_ATTENTION_AFTER_MS,
    MOVING_PRESSURE_PERSISTENT_AFTER_MS,
    MOVING_PRESSURE_WARNING_AFTER_MS,
)
from backend.app.services.risk_service import (
    PairMetric,
    _activity_state,
    _current_risk,
    _empty_baseline,
    _is_baseline_candidate,
)


DISTRIBUTION = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)
FOREFOOT_DISTRIBUTION = (0.30, 0.25, 0.20, 0.15, 0.05, 0.05)


def _frame(
    *,
    ax: float = 0.0,
    ay: float = 0.0,
    az: float = 9.80665,
    gx: float = 0.0,
    gy: float = 0.0,
    gz: float = 0.0,
    quality_flags: int = 0,
):
    return SimpleNamespace(
        ax=ax,
        ay=ay,
        az=az,
        gx=gx,
        gy=gy,
        gz=gz,
        quality_flags=quality_flags,
    )


def _metric(
    packet_seq: int,
    *,
    activity_state: str,
    left_distribution: tuple[float, ...] = DISTRIBUTION,
) -> PairMetric:
    left_total = right_total = 0.30
    return PairMetric(
        sync_id=7,
        packet_seq=packet_seq,
        timestamp_ms=packet_seq * 200,
        left_total=left_total,
        right_total=right_total,
        load_bias=0.0,
        load_diff=0.0,
        left_forefoot_ratio=sum(left_distribution[:4]),
        right_forefoot_ratio=sum(DISTRIBUTION[:4]),
        left_pressure=tuple(left_total * value for value in left_distribution),
        right_pressure=tuple(right_total * value for value in DISTRIBUTION),
        left_distribution=left_distribution,
        right_distribution=DISTRIBUTION,
        temperature_delta_c=(0.0, 0.0, 0.0, 0.0),
        activity_state=activity_state,
        motion_score=1.5 if activity_state == "moving" else 0.0,
    )


def _pressure_history(duration_ms: int, *, activity_state: str) -> list[PairMetric]:
    return [
        _metric(
            packet_seq,
            activity_state=activity_state,
            left_distribution=FOREFOOT_DISTRIBUTION,
        )
        for packet_seq in range(duration_ms // 200 + 1)
    ]


def test_classifies_stationary_and_moving_without_mounting_orientation() -> None:
    assert _activity_state(_frame(), _frame()) == ("stationary", 0.0)

    state, score = _activity_state(
        _frame(ax=0.0, ay=0.0, az=13.0),
        _frame(),
    )

    assert state == "moving"
    assert score >= 1.0


def test_missing_mpu_degrades_to_unknown_without_blocking_other_sensors() -> None:
    assert _activity_state(
        _frame(quality_flags=0x00000400),
        _frame(quality_flags=0x00000400),
    ) == ("unknown", 0.0)


@pytest.mark.parametrize("activity_state", ["stationary", "unknown"])
def test_baseline_accepts_nonmoving_or_missing_mpu(activity_state: str) -> None:
    assert _is_baseline_candidate(_metric(0, activity_state=activity_state)) is True


def test_baseline_rejects_walking_frames() -> None:
    assert _is_baseline_candidate(_metric(0, activity_state="moving")) is False


@pytest.mark.parametrize(
    ("activity_state", "duration_ms", "expected_level"),
    [
        ("stationary", ATTENTION_AFTER_MS, 1),
        ("moving", MOVING_PRESSURE_ATTENTION_AFTER_MS - 200, 0),
        ("moving", MOVING_PRESSURE_ATTENTION_AFTER_MS, 1),
        ("moving", MOVING_PRESSURE_WARNING_AFTER_MS, 2),
        ("moving", MOVING_PRESSURE_PERSISTENT_AFTER_MS, 3),
    ],
)
def test_walking_filters_single_step_peaks_but_keeps_sustained_pressure_risk(
    activity_state: str,
    duration_ms: int,
    expected_level: int,
) -> None:
    risk, _ = _current_risk(
        _pressure_history(duration_ms, activity_state=activity_state),
        _empty_baseline(),
    )

    assert risk.risk_level == expected_level
    if expected_level == 0:
        assert risk.risk_type == "normal"
    else:
        assert risk.risk_type == "forefoot_high"
        assert risk.risk_side == "left"
