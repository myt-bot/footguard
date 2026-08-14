from __future__ import annotations

from dataclasses import replace

import pytest

from backend.app.config import BASELINE_MIN_SAMPLES
from backend.app.services.risk_service import (
    PairMetric,
    _baseline_profile,
    _current_risk,
    _current_risks,
    _empty_baseline,
    _empty_temperature_reference,
    _gait_episode_from_segment,
    _gait_summary,
    _pressure_metric_from_window,
    _prebaseline_residual_suspect_channels,
    _regional_analysis,
    _signal,
    _signals,
)


LEFT_DISTRIBUTION = (0.05, 0.12, 0.22, 0.04, 0.13, 0.44)
RIGHT_DISTRIBUTION = (0.09, 0.07, 0.21, 0.06, 0.15, 0.42)


def _metric(
    packet_seq: int,
    *,
    left_total: float = 0.24,
    right_total: float = 0.26,
    left_distribution: tuple[float, ...] = LEFT_DISTRIBUTION,
    right_distribution: tuple[float, ...] = RIGHT_DISTRIBUTION,
    temperature_delta_c: tuple[float | None, ...] = (1.2, 2.4, -1.8, 0.8),
    motion_state: str = "unavailable",
) -> PairMetric:
    total = max(left_total + right_total, 1e-9)
    load_bias = (left_total - right_total) / total
    left_pressure = tuple(left_total * value for value in left_distribution)
    right_pressure = tuple(right_total * value for value in right_distribution)
    return PairMetric(
        sync_id=7,
        packet_seq=packet_seq,
        timestamp_ms=packet_seq * 200,
        left_total=left_total,
        right_total=right_total,
        load_bias=load_bias,
        load_diff=abs(load_bias),
        left_forefoot_ratio=sum(left_distribution[:4]),
        right_forefoot_ratio=sum(right_distribution[:4]),
        left_pressure=left_pressure,
        right_pressure=right_pressure,
        left_distribution=left_distribution,
        right_distribution=right_distribution,
        temperature_delta_c=temperature_delta_c,
        motion_state=motion_state,
    )


def _temperature_ready(baseline: object):
    return replace(
        baseline,
        temperature_offset_status=("normal_offset",) * 4,
    )


def test_learns_heel_heavy_personal_distribution() -> None:
    metrics = [_metric(index) for index in range(BASELINE_MIN_SAMPLES + 3)]

    baseline = _baseline_profile(metrics)

    assert baseline.ready is True
    assert baseline.left_distribution[5] == pytest.approx(0.44)
    assert baseline.right_distribution[5] == pytest.approx(0.42)
    assert baseline.temperature_delta_c == pytest.approx((1.2, 2.4, -1.8, 0.8))
    assert _signal(metrics[-1], baseline) is None

    regional = _regional_analysis(metrics[-1], baseline)
    assert regional.baseline_ready is True
    assert regional.left_pressure_scores == pytest.approx([0.0] * 6)
    assert regional.right_pressure_scores == pytest.approx([0.0] * 6)
    assert regional.temperature_delta_c == pytest.approx([0.0] * 4)


def test_20_hz_frames_need_about_eight_seconds_to_build_baseline() -> None:
    first_two_seconds = [
        replace(_metric(index), timestamp_ms=index * 50)
        for index in range(41)
    ]
    almost_eight_seconds = [
        replace(_metric(index), timestamp_ms=index * 50)
        for index in range(156)
    ]
    eight_second_window = [
        replace(_metric(index), timestamp_ms=index * 50)
        for index in range(157)
    ]

    after_two_seconds = _baseline_profile(first_two_seconds)
    before_eight_seconds = _baseline_profile(almost_eight_seconds)
    after_eight_seconds = _baseline_profile(eight_second_window)

    assert after_two_seconds.ready is False
    assert after_two_seconds.sample_count == 11
    assert before_eight_seconds.ready is False
    assert before_eight_seconds.sample_count == 39
    assert after_eight_seconds.ready is True
    assert after_eight_seconds.sample_count == BASELINE_MIN_SAMPLES


def test_low_load_multipoint_stance_can_build_personal_baseline() -> None:
    metrics = [
        _metric(index, left_total=0.0855, right_total=0.066)
        for index in range(BASELINE_MIN_SAMPLES)
    ]

    baseline = _baseline_profile(metrics)

    assert baseline.ready is True
    assert baseline.sample_count == BASELINE_MIN_SAMPLES


def test_low_load_floor_still_rejects_unloaded_multipoint_residuals() -> None:
    uniform = (1 / 6,) * 6
    metrics = [
        _metric(
            index,
            left_total=0.039,
            right_total=0.039,
            left_distribution=uniform,
            right_distribution=uniform,
        )
        for index in range(BASELINE_MIN_SAMPLES)
    ]

    assert _baseline_profile(metrics).ready is False


def test_20_hz_empty_reference_keeps_warmup_and_200_ms_sampling() -> None:
    empty_delta = (3.0, -2.8, 0.4, 2.4)

    def unloaded_metric(index: int) -> PairMetric:
        return replace(
            _metric(
                index,
                left_total=0.0,
                right_total=0.0,
                temperature_delta_c=empty_delta,
            ),
            timestamp_ms=index * 50,
        )

    too_early = _empty_temperature_reference(
        [unloaded_metric(index) for index in range(341)]
    )
    ready = _empty_temperature_reference(
        [unloaded_metric(index) for index in range(537)]
    )

    assert too_early[3] == ("unstable",) * 4
    assert ready[3] == (
        "assembly_offset",
        "assembly_offset",
        "normal_offset",
        "assembly_offset",
    )


def test_rejects_off_ground_one_sided_and_single_point_samples() -> None:
    single_point = (1.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    metrics = [
        *[
            _metric(index, left_total=0.0, right_total=0.0)
            for index in range(BASELINE_MIN_SAMPLES)
        ],
        *[
            _metric(
                BASELINE_MIN_SAMPLES + index,
                left_total=0.30,
                right_total=0.02,
            )
            for index in range(BASELINE_MIN_SAMPLES)
        ],
        *[
            _metric(
                BASELINE_MIN_SAMPLES * 2 + index,
                left_distribution=single_point,
                right_distribution=single_point,
            )
            for index in range(BASELINE_MIN_SAMPLES)
        ],
    ]

    assert _baseline_profile(metrics).ready is False


def test_baseline_rejects_too_few_responsive_channels_on_one_foot() -> None:
    sparse_left = (0.34, 0.33, 0.33, 0.0, 0.0, 0.0)
    metrics = [
        _metric(index, left_distribution=sparse_left)
        for index in range(BASELINE_MIN_SAMPLES)
    ]

    baseline = _baseline_profile(metrics)

    assert baseline.ready is False
    assert baseline.sample_count == BASELINE_MIN_SAMPLES


def test_unloaded_temperature_alert_keeps_pressure_risks_suppressed() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    heated_off_ground = _metric(
        BASELINE_MIN_SAMPLES,
        left_total=0.01,
        right_total=0.03,
        temperature_delta_c=(8.0, 2.4, -1.8, 0.8),
    )
    normal_off_ground = _metric(
        BASELINE_MIN_SAMPLES + 1,
        left_total=0.01,
        right_total=0.03,
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )
    single_foot_load = _metric(
        BASELINE_MIN_SAMPLES + 2,
        left_total=0.20,
        right_total=0.0,
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )

    assert baseline.ready is True
    assert _signal(heated_off_ground, baseline) == (
        "temperature_asymmetry",
        "left",
    )
    assert _signal(normal_off_ground, baseline) is None
    assert _signal(single_foot_load, baseline) == ("left_load_bias", "left")


def test_single_residual_pressure_point_cannot_create_load_bias() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    unloaded_right_residual = _metric(
        BASELINE_MIN_SAMPLES + 3,
        left_total=0.0,
        right_total=0.12,
        left_distribution=LEFT_DISTRIBUTION,
        right_distribution=(0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )

    assert baseline.ready is True
    assert _signal(unloaded_right_residual, baseline) is None


def test_load_bias_and_forefoot_risk_are_reported_together() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    forefoot_heavy = (0.30, 0.25, 0.20, 0.15, 0.05, 0.05)
    metrics = [
        _metric(
            100 + index,
            left_total=0.45,
            right_total=0.12,
            left_distribution=forefoot_heavy,
        )
        for index in range(55)
    ]

    risks, _ = _current_risks(metrics, baseline)

    assert {(risk.risk_type, risk.risk_side) for risk in risks} == {
        ("left_load_bias", "left"),
        ("forefoot_high", "left"),
        ("medial_load_concentration", "left"),
    }
    assert risks[0].risk_type == "forefoot_high"
    assert all(risk.risk_level == 2 for risk in risks)


def test_medial_and_lateral_concentration_are_independent_of_forefoot_total() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    left_lateral = (0.04, 0.30, 0.05, 0.04, 0.13, 0.44)
    right_medial = (0.20, 0.02, 0.04, 0.17, 0.15, 0.42)
    lateral_risks, _ = _current_risks(
        [
            _metric(100 + index, left_distribution=left_lateral)
            for index in range(55)
        ],
        baseline,
    )
    medial_risks, _ = _current_risks(
        [
            _metric(200 + index, right_distribution=right_medial)
            for index in range(55)
        ],
        baseline,
    )

    assert ("lateral_load_concentration", "left") in {
        (item.risk_type, item.risk_side) for item in lateral_risks
    }
    assert ("medial_load_concentration", "right") in {
        (item.risk_type, item.risk_side) for item in medial_risks
    }


def test_bilateral_forefoot_risk_is_consolidated() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    forefoot = (0.16, 0.18, 0.30, 0.16, 0.10, 0.10)
    risks, _ = _current_risks(
        [
            _metric(
                300 + index,
                left_distribution=forefoot,
                right_distribution=forefoot,
            )
            for index in range(55)
        ],
        baseline,
    )

    forefoot_risks = [item for item in risks if item.risk_type == "forefoot_high"]
    assert len(forefoot_risks) == 1
    assert forefoot_risks[0].risk_side == "both"


@pytest.mark.parametrize(
    ("sample_count", "expected_level"),
    [(25, 0), (26, 1), (51, 2), (101, 3)],
)
def test_pressure_risk_uses_5_10_20_second_boundaries(
    sample_count: int, expected_level: int
) -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    metrics = [
        _metric(100 + index, left_total=0.45, right_total=0.15)
        for index in range(sample_count)
    ]

    risk, _ = _current_risk(metrics, baseline)

    assert risk.risk_level == expected_level


@pytest.mark.parametrize(
    ("sample_count", "expected_level"),
    [(40, 0), (41, 1), (76, 2), (151, 3)],
)
def test_temperature_risk_uses_8_15_30_second_boundaries(
    sample_count: int, expected_level: int
) -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    metrics = [
        _metric(
            200 + index,
            left_total=0,
            right_total=0,
            temperature_delta_c=(3.4, 0.2, -0.1, 0.0),
        )
        for index in range(sample_count)
    ]

    risk, _ = _current_risk(metrics, baseline)

    assert risk.risk_level == expected_level


def test_forefoot_risk_works_with_two_covered_forefoot_channels() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    partially_covered = replace(
        baseline,
        pressure_channel_trust=(False, True, True, False, True, True) + (True,) * 6,
        pressure_channel_contact_trust=(
            False,
            True,
            True,
            False,
            True,
            True,
        ) + (True,) * 6,
    )
    forefoot_heavy = (0.0, 0.38, 0.34, 0.0, 0.10, 0.18)
    metric = _metric(
        100,
        left_distribution=forefoot_heavy,
    )

    assert ("forefoot_high", "left") in _signals(metric, partially_covered)


def test_forefoot_risk_recovers_two_uncovered_channels_without_heel_contact() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    partially_covered = replace(
        baseline,
        pressure_channel_trust=(False, True, True, False, True, True) + (True,) * 6,
        pressure_channel_contact_trust=(
            False,
            True,
            True,
            False,
            True,
            True,
        ) + (True,) * 6,
    )
    uncovered_forefoot_loaded = _metric(
        101,
        left_distribution=(0.52, 0.0, 0.0, 0.48, 0.0, 0.0),
    )

    assert ("forefoot_high", "left") in _signals(
        uncovered_forefoot_loaded,
        partially_covered,
    )


def test_residual_channel_is_raw_valid_but_excluded_from_analysis() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    diagnosed = replace(
        baseline,
        pressure_channel_contact_trust=(True,) * 8 + (False,) + (True,) * 3,
    )

    regional = _regional_analysis(
        _metric(BASELINE_MIN_SAMPLES),
        diagnosed,
        baseline_trust=baseline.pressure_channel_trust,
        residual_suspects=(False,) * 8 + (True,) + (False,) * 3,
    )

    assert regional.right_pressure_valid[2] is True
    assert regional.right_pressure_baseline_trusted[2] is True
    assert regional.right_pressure_analysis_valid[2] is False
    assert regional.right_pressure_channel_status[2] == "residual_suspect"


def test_regional_pressure_is_unavailable_without_multipoint_contact() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    unloaded = _metric(
        BASELINE_MIN_SAMPLES,
        left_total=0.0,
        right_total=0.0,
    )

    regional = _regional_analysis(unloaded, baseline)

    assert regional.pressure_available is False


def test_residual_on_unloaded_foot_does_not_reverse_real_single_foot_bias() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    left_contact_with_right_residual = _metric(
        BASELINE_MIN_SAMPLES + 4,
        left_total=0.08,
        right_total=0.12,
        left_distribution=LEFT_DISTRIBUTION,
        right_distribution=(0.0, 0.0, 1.0, 0.0, 0.0, 0.0),
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )

    assert _signal(left_contact_with_right_residual, baseline) == (
        "left_load_bias",
        "left",
    )
    assert ("forefoot_high", "right") not in _signals(
        left_contact_with_right_residual, baseline
    )


def test_single_valid_temperature_pair_cannot_trigger_temperature_risk() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    single_valid_pair = _metric(
        BASELINE_MIN_SAMPLES + 1,
        temperature_delta_c=(8.0, None, None, None),
    )

    assert baseline.ready is True
    assert _signal(single_valid_pair, baseline) is None


def test_large_raw_temperature_delta_is_not_hidden_by_baseline() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    shifted_baseline = replace(
        baseline,
        temperature_delta_c=(6.0, 2.4, -1.8, 0.8),
    )
    heated_off_ground = _metric(
        BASELINE_MIN_SAMPLES + 1,
        left_total=0.0,
        right_total=0.0,
        temperature_delta_c=(7.0, 2.4, -1.8, 0.8),
    )

    assert shifted_baseline.ready is True
    # The corrected delta is only 1 C, but the App-visible raw delta is 7 C.
    assert _signal(heated_off_ground, shifted_baseline) == (
        "temperature_asymmetry",
        "left",
    )


def test_baseline_temperature_shift_needs_visible_raw_support() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    shifted_baseline = replace(
        baseline,
        temperature_delta_c=(0.0, -3.0, 0.0, 0.0),
    )
    almost_equal_current_readings = _metric(
        BASELINE_MIN_SAMPLES + 1,
        left_total=0.0,
        right_total=0.0,
        temperature_delta_c=(0.2, 0.4, -0.3, 0.1),
    )

    assert _signal(almost_equal_current_readings, shifted_baseline) is None


def test_unloaded_raw_delta_of_2_97_c_triggers_right_alert() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    heated_off_ground = _metric(
        BASELINE_MIN_SAMPLES + 2,
        left_total=0.0,
        right_total=0.0,
        temperature_delta_c=(0.61, 0.36, -2.97, -0.99),
    )

    assert baseline.ready is True
    assert _signal(heated_off_ground, baseline) == (
        "temperature_asymmetry",
        "right",
    )


def test_robust_baseline_ignores_a_multichannel_hand_press_outlier() -> None:
    metrics = [_metric(index) for index in range(BASELINE_MIN_SAMPLES + 5)]
    metrics.append(
        _metric(
            BASELINE_MIN_SAMPLES + 5,
            left_distribution=(0.55, 0.05, 0.05, 0.05, 0.10, 0.20),
            right_distribution=(0.05, 0.55, 0.05, 0.05, 0.10, 0.20),
        )
    )

    baseline = _baseline_profile(metrics)

    assert baseline.ready is True
    assert baseline.left_distribution == pytest.approx(LEFT_DISTRIBUTION)
    assert baseline.right_distribution == pytest.approx(RIGHT_DISTRIBUTION)


def test_suppresses_heatmap_until_personal_baseline_is_ready() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES - 1)]
    )
    forefoot = _metric(
        BASELINE_MIN_SAMPLES,
        left_distribution=(0.30, 0.25, 0.20, 0.15, 0.05, 0.05),
        temperature_delta_c=(0.0, 0.0, 0.0, 0.0),
    )

    assert baseline.ready is False
    # A new wearing session must finish its personal pressure baseline before
    # pressure risks or motor actions are enabled.
    assert _signal(forefoot, baseline) is None

    regional = _regional_analysis(forefoot, baseline)
    assert regional.baseline_ready is False
    assert regional.left_pressure_scores == [0.0] * 6
    assert regional.right_pressure_scores == [0.0] * 6
    assert regional.left_temperature_scores == [0.0] * 4
    assert regional.right_temperature_scores == [0.0] * 4


def test_moving_samples_do_not_train_personal_baseline() -> None:
    moving = [
        _metric(index, motion_state="moving")
        for index in range(BASELINE_MIN_SAMPLES + 3)
    ]
    stationary = [
        _metric(index, motion_state="stationary")
        for index in range(BASELINE_MIN_SAMPLES + 3)
    ]
    unavailable = [
        _metric(index, motion_state="unavailable")
        for index in range(BASELINE_MIN_SAMPLES + 3)
    ]

    assert _baseline_profile(moving).ready is False
    assert _baseline_profile(stationary).ready is True
    # Systems without a valid MPU keep the existing pressure-only behavior.
    assert _baseline_profile(unavailable).ready is True


def test_gait_summary_detects_alternating_load_transfer() -> None:
    metrics = []
    for index in range(61):
        phase = (index // 3) % 2
        metrics.append(
            replace(
                _metric(
                    index,
                    left_total=0.45 if phase == 0 else 0.10,
                    right_total=0.10 if phase == 0 else 0.45,
                    motion_state="moving",
                ),
                log_load_ratio=1.50 if phase == 0 else -1.50,
            )
        )

    baseline = replace(
        _empty_baseline(), ready=True, load_ratio=0.0, load_ratio_mad=0.05
    )
    gait = _gait_summary(metrics, baseline)

    assert gait.state == "walking"
    assert gait.step_count >= 18
    assert abs(gait.left_steps - gait.right_steps) <= 1
    assert gait.cadence_spm == pytest.approx(100.0, abs=0.1)


def test_gait_summary_reports_stationary_without_false_steps() -> None:
    metrics = [_metric(index, motion_state="stationary") for index in range(31)]

    gait = _gait_summary(metrics, _empty_baseline())

    assert gait.state == "stationary"
    assert gait.step_count == 0
    assert gait.cadence_spm is None


def test_gait_summary_retains_last_completed_walk_while_stationary() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    walking = [
        replace(
            _metric(
                100 + index,
                left_total=0.45 if index % 6 < 3 else 0.10,
                right_total=0.10 if index % 6 < 3 else 0.45,
                motion_state="moving",
            ),
            log_load_ratio=1.50 if index % 6 < 3 else -1.50,
        )
        for index in range(60)
    ]
    stationary = [
        _metric(160 + index, motion_state="stationary")
        for index in range(12)
    ]

    gait = _gait_summary(walking + stationary, baseline)

    assert gait.state == "stationary"
    assert gait.step_count == 0
    assert gait.last_completed_episode is not None
    assert gait.last_completed_episode.step_count >= 6


def test_old_gait_events_do_not_revive_after_one_new_motion_frame() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    walking = [
        replace(
            _metric(
                100 + index,
                left_total=0.45 if index % 6 < 3 else 0.10,
                right_total=0.10 if index % 6 < 3 else 0.45,
                motion_state="moving",
            ),
            log_load_ratio=1.50 if index % 6 < 3 else -1.50,
        )
        for index in range(45)
    ]
    pause = [
        _metric(145 + index, motion_state="stationary")
        for index in range(15)
    ]
    nudge = _metric(160, motion_state="moving")

    gait = _gait_summary(walking + pause + [nudge], baseline)

    assert gait.state != "walking"


def _gait_episode_metrics(
    *,
    intervals_ms: tuple[int, ...] = (600, 600, 600, 600, 600, 600, 600),
    left_total: float = 0.45,
    right_total: float = 0.45,
    left_distribution: tuple[float, ...] = LEFT_DISTRIBUTION,
    right_distribution: tuple[float, ...] = RIGHT_DISTRIBUTION,
) -> list[PairMetric]:
    timestamps = [0]
    for interval in intervals_ms:
        timestamps.append(timestamps[-1] + interval)
    return [
        replace(
            _metric(
                index,
                left_total=left_total if index % 2 == 0 else 0.10,
                right_total=0.10 if index % 2 == 0 else right_total,
                left_distribution=left_distribution,
                right_distribution=right_distribution,
                motion_state="moving",
            ),
            timestamp_ms=timestamp,
            log_load_ratio=1.50 if index % 2 == 0 else -1.50,
        )
        for index, timestamp in enumerate(timestamps)
    ]


def test_gait_episode_detects_walking_load_asymmetry() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )

    episode = _gait_episode_from_segment(
        _gait_episode_metrics(left_total=0.75, right_total=0.30), baseline
    )

    assert episode is not None
    issue = next(
        item for item in episode.issues
        if item.issue_type == "walking_load_asymmetry"
    )
    assert issue.side == "left"
    assert episode.left_load_index > episode.right_load_index


def test_gait_episode_detects_repeated_regional_concentration() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    medial_forefoot = (0.30, 0.10, 0.05, 0.25, 0.10, 0.20)

    episode = _gait_episode_from_segment(
        _gait_episode_metrics(left_distribution=medial_forefoot), baseline
    )

    assert episode is not None
    assert any(
        item.issue_type == "walking_medial_concentration"
        and item.side == "left"
        for item in episode.issues
    )


def test_gait_episode_detects_step_timing_instability() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )

    episode = _gait_episode_from_segment(
        _gait_episode_metrics(
            intervals_ms=(300, 900, 300, 900, 300, 900, 300, 900)
        ),
        baseline,
    )

    assert episode is not None
    assert any(
        item.issue_type == "step_timing_instability" for item in episode.issues
    )


def test_low_cadence_is_displayed_without_becoming_an_issue() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )

    episode = _gait_episode_from_segment(
        _gait_episode_metrics(intervals_ms=(2500, 2500, 2500, 2500, 2500)),
        baseline,
    )

    assert episode is not None
    assert episode.cadence_spm == pytest.approx(24.0)
    assert all(item.issue_type != "low_cadence" for item in episode.issues)


def test_discontinuous_standing_samples_do_not_form_a_baseline() -> None:
    first = [
        replace(_metric(index), timestamp_ms=index * 200)
        for index in range(25)
    ]
    second = [
        replace(_metric(100 + index), timestamp_ms=20_000 + index * 200)
        for index in range(25)
    ]

    baseline = _baseline_profile([*first, *second])

    assert baseline.ready is False
    assert baseline.sample_count == 25


def test_prebaseline_fixed_single_point_is_diagnosed_as_residual() -> None:
    single_right_p3 = (0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
    metrics = [
        _metric(index, right_total=0.12, right_distribution=single_right_p3)
        for index in range(15)
    ]

    suspects = _prebaseline_residual_suspect_channels(metrics)

    assert suspects[8] is True
    assert sum(suspects) == 1


def test_sustained_risk_tolerates_dropped_realtime_packets() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    risk_metrics = [
        replace(
            _metric(
                100 + index * 4,
                left_total=0.45,
                right_total=0.15,
                temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
            ),
            timestamp_ms=10_000 + index * 800,
        )
        for index in range(12)
    ]

    risk, _ = _current_risk(risk_metrics, baseline)

    assert risk.risk_type == "left_load_bias"
    assert risk.risk_side == "left"
    assert risk.risk_level == 1
    assert risk.duration_ms == 8_800


def test_sustained_risk_tolerates_observed_android_batch_gap() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    risk_metrics = [
        replace(
            _metric(200 + index, left_total=0.45, right_total=0.15),
            timestamp_ms=20_000 + index * 1_400,
        )
        for index in range(8)
    ]

    risks, _ = _current_risks(risk_metrics, baseline)

    load_bias = next(risk for risk in risks if risk.risk_type == "left_load_bias")
    assert load_bias.risk_level == 1
    assert load_bias.duration_ms == 9_800

def test_pressure_median_rejects_one_frame_spike() -> None:
    baseline_metrics = [
        _metric(index) for index in range(BASELINE_MIN_SAMPLES)
    ]
    baseline = _baseline_profile(baseline_metrics)
    normal = [
        _metric(BASELINE_MIN_SAMPLES + index) for index in range(5)
    ]
    spike = _metric(
        BASELINE_MIN_SAMPLES + 5,
        left_total=0.48,
        right_total=0.08,
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )
    tail = [
        _metric(BASELINE_MIN_SAMPLES + 6 + index) for index in range(4)
    ]

    metrics = [*baseline_metrics, *normal, spike, *tail]
    smoothed = _pressure_metric_from_window(metrics)
    risk, _ = _current_risk(metrics, baseline)

    assert smoothed.load_bias == pytest.approx(-0.04)
    assert risk.risk_type == "normal"


def test_sustained_pressure_change_survives_brief_normal_frame() -> None:
    baseline_metrics = [
        _metric(index) for index in range(BASELINE_MIN_SAMPLES)
    ]
    baseline = _baseline_profile(baseline_metrics)
    sustained = [
        _metric(
            100 + index,
            left_total=0.45,
            right_total=0.15,
            temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
        )
        for index in range(55)
    ]
    sustained[35] = _metric(
        135,
        temperature_delta_c=(1.2, 2.4, -1.8, 0.8),
    )

    risk, metric = _current_risk([*baseline_metrics, *sustained], baseline)

    assert metric.load_bias == pytest.approx(0.5)
    assert risk.risk_type == "left_load_bias"
    assert risk.risk_side == "left"
    assert risk.risk_level == 2


def test_regional_analysis_ignores_low_evidence_channel() -> None:
    metrics = [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    baseline = _baseline_profile(metrics)
    current = metrics[-1]
    low_left = list(current.left_pressure)
    low_right = list(current.right_pressure)
    low_left[0] = 0.004
    low_right[0] = 0.0
    low_evidence = replace(
        current,
        left_pressure=tuple(low_left),
        right_pressure=tuple(low_right),
    )

    regional = _regional_analysis(low_evidence, baseline)

    assert regional.left_pressure_scores[0] == 0.0
    assert regional.right_pressure_scores[0] == 0.0




def test_risk_continuity_uses_exit_hysteresis() -> None:
    baseline_metrics = [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    baseline = _baseline_profile(baseline_metrics)
    high_forefoot = (0.10, 0.15, 0.25, 0.05, 0.12, 0.33)
    near_exit = (0.08, 0.13, 0.23, 0.05, 0.13, 0.38)
    history = [
        _metric(
            100 + index,
            left_distribution=(
                near_exit if 18 <= index < 24 else high_forefoot
            ),
        )
        for index in range(58)
    ]

    risk, _ = _current_risk(
        history,
        baseline,
    )

    assert (risk.risk_type, risk.risk_side) == ("forefoot_high", "left")
    assert risk.risk_level >= 2
    assert risk.duration_ms >= 6_000


def test_temperature_asymmetry_has_priority_over_competing_pressure_signals() -> None:
    baseline_metrics = [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    baseline = _temperature_ready(_baseline_profile(baseline_metrics))
    history = [
        _metric(
            200 + index,
            left_total=0.42,
            right_total=0.10,
            left_distribution=(0.12, 0.18, 0.25, 0.08, 0.12, 0.25),
            temperature_delta_c=(4.2, 2.4, -1.8, 0.8),
        )
        for index in range(80)
    ]

    risk, _ = _current_risk(
        history,
        baseline,
    )

    assert (risk.risk_type, risk.risk_side) == ("temperature_asymmetry", "left")
    assert risk.risk_level >= 2
    assert risk.duration_ms >= 15_000


def test_temperature_baseline_correction_wins_over_raw_offset() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    shifted_baseline = replace(
        baseline,
        temperature_delta_c=(3.0, 5.0, 0.0, 0.0),
    )
    visible_left_heat = _metric(
        300,
        left_total=0.0,
        right_total=0.0,
        temperature_delta_c=(3.2, -2.4, 0.0, 0.0),
    )

    # The relative T2 change is the meaningful signal; a fixed raw T1 offset
    # must not override it.
    assert _signal(visible_left_heat, shifted_baseline) == (
        "temperature_asymmetry",
        "right",
    )


def test_four_temperature_empty_offsets_are_classified_independently() -> None:
    empty_delta = (3.0, -2.8, 0.4, 2.4)
    metrics = [
        _metric(index, left_total=0.0, right_total=0.0, temperature_delta_c=empty_delta)
        for index in range(140)
    ] + [
        _metric(140 + index, temperature_delta_c=empty_delta)
        for index in range(BASELINE_MIN_SAMPLES)
    ]
    baseline = _baseline_profile(metrics)

    assert baseline.ready is True
    assert baseline.temperature_offset_status == (
        "assembly_offset",
        "assembly_offset",
        "normal_offset",
        "assembly_offset",
    )


def test_temperature_offset_compensation_requires_two_zones_and_wearing_baseline() -> None:
    empty_delta = (3.0, -2.8, 0.4, 2.4)
    metrics = [
        _metric(index, left_total=0.0, right_total=0.0, temperature_delta_c=empty_delta)
        for index in range(140)
    ] + [
        _metric(140 + index, temperature_delta_c=empty_delta)
        for index in range(BASELINE_MIN_SAMPLES)
    ]
    baseline = _baseline_profile(metrics)
    unchanged = _metric(200, left_total=0.0, right_total=0.0, temperature_delta_c=empty_delta)
    heated_one = _metric(201, left_total=0.0, right_total=0.0, temperature_delta_c=(6.0, None, None, None))
    heated_two = _metric(202, left_total=0.0, right_total=0.0, temperature_delta_c=(6.0, -5.8, None, None))

    assert _signal(unchanged, baseline) is None
    assert _signal(heated_one, baseline) is None
    assert _signal(heated_two, baseline) == ("temperature_asymmetry", "left")
    assert _signal(heated_two, _empty_baseline()) is None


def test_sustained_pressure_duration_does_not_roll_back_after_window_slides() -> None:
    baseline = _baseline_profile(
        [_metric(index) for index in range(BASELINE_MIN_SAMPLES)]
    )
    history = [
        _metric(
            100 + index,
            left_total=0.10,
            right_total=0.45,
            temperature_delta_c=(0.0, 0.0, 0.0, 0.0),
        )
        for index in range(150)
    ]

    risks, _ = _current_risks(history, baseline)

    right_bias = next(
        risk for risk in risks if risk.risk_type == "right_load_bias"
    )
    assert right_bias.duration_ms >= 29_000


def test_temperature_continuity_survives_ble_sync_id_rotation() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    history = [
        replace(
            _metric(
                400 + index,
                left_total=0.0,
                right_total=0.0,
                temperature_delta_c=(3.4, 0.2, -0.1, 0.0),
            ),
            sync_id=1_000 + index,
            timestamp_ms=20_000 + index * 200,
        )
        for index in range(41)
    ]

    risk, _ = _current_risk(history, baseline)

    assert risk.risk_type == "temperature_asymmetry"
    assert risk.risk_side == "left"
    assert risk.risk_level == 1
    assert risk.duration_ms == 8_000


def test_temperature_risk_tolerates_brief_internal_adc_dropout() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    history = [
        replace(
            _metric(
                500 + index,
                left_total=0.0,
                right_total=0.0,
                temperature_delta_c=(
                    (1.2, 2.4, -1.8, 0.8)
                    if 18 <= index <= 21
                    else (3.4, 2.4, -1.8, 0.8)
                ),
            ),
            timestamp_ms=30_000 + index * 200,
        )
        for index in range(80)
    ]

    risk, _ = _current_risk(history, baseline)

    assert risk.risk_type == "temperature_asymmetry"
    assert risk.risk_side == "left"
    assert risk.risk_level == 2
    assert risk.duration_ms == 15_800


def test_temperature_risk_clears_after_dropout_grace() -> None:
    baseline = _temperature_ready(
        _baseline_profile([_metric(index) for index in range(BASELINE_MIN_SAMPLES)])
    )
    history = [
        replace(
            _metric(
                600 + index,
                left_total=0.0,
                right_total=0.0,
                temperature_delta_c=(
                    (3.4, 2.4, -1.8, 0.8)
                    if index < 20
                    else (1.2, 2.4, -1.8, 0.8)
                ),
            ),
            timestamp_ms=40_000 + index * 200,
        )
        for index in range(28)
    ]

    risk, _ = _current_risk(history, baseline)

    assert risk.risk_type == "normal"
    assert risk.risk_side == "none"
    assert risk.risk_level == 0
    assert risk.duration_ms == 0
