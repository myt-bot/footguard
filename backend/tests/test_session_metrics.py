from __future__ import annotations

import json

from backend.app.database import create_database
from backend.app.models import CalibrationProfile, SensorFrame
from backend.app.schemas import RiskState
from backend.app.services.session_metrics import component_feedback, summarize_improvements


BASELINE = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)


def _profile() -> CalibrationProfile:
    return CalibrationProfile(
        profile_key="active_wearing",
        protocol_version=1,
        sensor_layout_version="layout_6p4t_v1",
        left_device_id="left-device",
        right_device_id="right-device",
        sample_count=40,
        created_at_ms=1,
        load_ratio=0.0,
        load_ratio_mad=0.02,
        left_distribution_json=json.dumps(BASELINE),
        right_distribution_json=json.dumps(BASELINE),
        left_forefoot_mad=0.01,
        right_forefoot_mad=0.01,
        regional_share_mad_json=json.dumps((0.01, 0.01, 0.01, 0.01)),
        pressure_asymmetry_json=json.dumps((0.0,) * 6),
        pressure_channel_trust_json=json.dumps((True,) * 12),
        temperature_delta_json=json.dumps((0.0,) * 4),
        temperature_valid_json=json.dumps((True,) * 4),
        empty_temperature_delta_json=json.dumps((0.0,) * 4),
        empty_temperature_mad_json=json.dumps((0.0,) * 4),
        empty_temperature_slope_json=json.dumps((0.0,) * 4),
        temperature_offset_status_json=json.dumps(("normal_offset",) * 4),
        wearing_temperature_mad_json=json.dumps((0.1,) * 4),
    )


def _frame(
    side: str,
    timestamp_ms: int,
    packet_seq: int,
    pressure: tuple[float, ...],
    *,
    moving: bool = False,
    quality_flags: int = 0,
) -> SensorFrame:
    return SensorFrame(
        protocol_version=1,
        sensor_layout_version="layout_6p4t_v1",
        device_id=f"{side}-device",
        side=side,
        sync_id=packet_seq,
        packet_seq=packet_seq,
        timestamp_ms=timestamp_ms,
        p1=pressure[0],
        p2=pressure[1],
        p3=pressure[2],
        p4=pressure[3],
        p5=pressure[4],
        p6=pressure[5],
        t1=30.0,
        t2=30.0,
        t3=30.0,
        t4=30.0,
        ax=0.0,
        ay=0.0,
        az=9.80665,
        gx=30.0 if moving else 0.0,
        gy=0.0,
        gz=0.0,
        battery=90,
        quality_flags=quality_flags,
        source="ble",
    )


def _add_pairs(
    session,
    start_ms: int,
    left: tuple[float, ...],
    right: tuple[float, ...],
    *,
    moving: bool = False,
) -> None:
    for offset in range(5):
        timestamp = start_ms + offset * 500
        packet = start_ms + offset
        session.add(_frame("left", timestamp, packet, left, moving=moving))
        session.add(_frame("right", timestamp, packet, right, moving=moving))
    session.commit()


def _components(*types: tuple[str, str]) -> list[RiskState]:
    return [
        RiskState(risk_type=risk_type, risk_side=side, risk_level=3, duration_ms=20_000)
        for risk_type, side in types
    ]


def test_pressure_components_use_baseline_adjusted_static_windows(tmp_path) -> None:
    engine, factory = create_database(f"sqlite:///{tmp_path / 'metrics.db'}")
    try:
        with factory() as session:
            session.add(_profile())
            session.commit()
            _add_pairs(
                session,
                7_000,
                (0.28, 0.10, 0.16, 0.22, 0.12, 0.12),
                (0.04, 0.16, 0.04, 0.06, 0.05, 0.05),
            )
            _add_pairs(session, 20_000, tuple(value * 0.6 for value in BASELINE), tuple(value * 0.55 for value in BASELINE))
            result = component_feedback(
                session,
                _components(
                    ("left_load_bias", "left"),
                    ("forefoot_high", "left"),
                    ("medial_load_concentration", "left"),
                    ("lateral_load_concentration", "right"),
                    ("temperature_asymmetry", "left"),
                ),
                10_000,
            )

            pressure = result[:4]
            assert all(item.effect_label == "effective" for item in pressure)
            assert all(item.improvement_ratio is not None for item in pressure)
            assert result[-1].effect_label == "observation_only"
            assert result[-1].improvement_ratio is None
            assert {item.metric_unit for item in pressure} == {"ratio", "percentage_point"}
            summary = summarize_improvements(result)
            assert len(summary) == 4
            assert all(item.evaluated_count == 1 for item in summary)
    finally:
        engine.dispose()


def test_pressure_component_reports_worsened_and_insufficient_data(tmp_path) -> None:
    engine, factory = create_database(f"sqlite:///{tmp_path / 'metrics.db'}")
    try:
        with factory() as session:
            session.add(_profile())
            session.commit()
            _add_pairs(session, 37_000, tuple(value * 0.7 for value in BASELINE), tuple(value * 0.3 for value in BASELINE))
            _add_pairs(session, 50_000, tuple(value * 0.9 for value in BASELINE), tuple(value * 0.1 for value in BASELINE))
            worsened = component_feedback(
                session,
                _components(("left_load_bias", "left")),
                40_000,
            )[0]
            assert worsened.effect_label == "worsened"
            assert worsened.improvement_ratio is not None and worsened.improvement_ratio < 0

            insufficient = component_feedback(
                session,
                _components(("forefoot_high", "left")),
                90_000,
            )[0]
            assert insufficient.effect_label == "unknown"
            assert insufficient.before_value is None
            assert insufficient.after_value is None
    finally:
        engine.dispose()


def test_pressure_feedback_tolerates_one_invalid_trusted_channel(tmp_path) -> None:
    engine, factory = create_database(f"sqlite:///{tmp_path / 'metrics.db'}")
    try:
        with factory() as session:
            session.add(_profile())
            session.commit()
            before_left = tuple(value * 0.8 for value in BASELINE)
            before_right = tuple(value * 0.3 for value in BASELINE)
            after_left = tuple(value * 0.55 for value in BASELINE)
            after_right = tuple(value * 0.5 for value in BASELINE)
            for start_ms, left, right in (
                (97_000, before_left, before_right),
                (110_000, after_left, after_right),
            ):
                for offset in range(5):
                    timestamp = start_ms + offset * 500
                    packet = start_ms + offset
                    session.add(
                        _frame(
                            "left",
                            timestamp,
                            packet,
                            left,
                            quality_flags=1 << 5,
                        )
                    )
                    session.add(_frame("right", timestamp, packet, right))
            session.commit()

            feedback = component_feedback(
                session,
                _components(("left_load_bias", "left")),
                100_000,
            )[0]

            assert feedback.effect_label in {"effective", "partial", "ineffective"}
            assert feedback.before_value is not None
            assert feedback.after_value is not None
    finally:
        engine.dispose()
