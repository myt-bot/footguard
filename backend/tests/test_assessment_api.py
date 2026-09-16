from __future__ import annotations

import json
import sys
from time import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.main import create_app
from backend.app.models import CalibrationState, RiskEvent, SensorFrame
from backend.app.services.assessment_service import (
    assessment_summary,
    current_rating,
    record_temperature_event,
    save_session_snapshot,
)


def _frame(side: str, packet_seq: int, timestamp_ms: int) -> SensorFrame:
    return SensorFrame(
        protocol_version=1,
        sensor_layout_version="layout_6p4t_v1",
        device_id=f"foot_{side}",
        side=side,
        sync_id=1,
        packet_seq=packet_seq,
        timestamp_ms=timestamp_ms,
        p1=100,
        p2=100,
        p3=100,
        p4=100,
        p5=100,
        p6=100,
        t1=30,
        t2=30,
        t3=30,
        t4=30,
        ax=0,
        ay=0,
        az=1,
        gx=0,
        gy=0,
        gz=0,
        battery=90,
        quality_flags=0,
        source="ble",
    )


@pytest.fixture()
def app(tmp_path: Path):
    application = create_app(f"sqlite:///{(tmp_path / 'assessment.db').as_posix()}")
    yield application
    application.state.engine.dispose()


@pytest.fixture()
def client(app):
    with TestClient(app) as test_client:
        yield test_client


def test_health_profile_and_glucose_are_background_data(client: TestClient) -> None:
    profile = client.put(
        "/api/v1/health-profile",
        json={
            "ulcer_or_amputation": "no",
            "sensory_or_circulation_issue": "unknown",
        },
    )
    assert profile.status_code == 200
    assert profile.json()["completeness"] == "incomplete"

    glucose = client.post(
        "/api/v1/glucose",
        json={
            "value": 180,
            "unit": "mg/dL",
            "context": "post_meal",
            "measured_at_ms": 1_760_000_000_000,
            "note": "home meter",
        },
    )
    assert glucose.status_code == 200
    assert glucose.json()["value_mmol_l"] == pytest.approx(10.0)
    assert client.get("/api/v1/glucose").json()[0]["unit"] == "mg/dL"

    invalid = client.post(
        "/api/v1/glucose",
        json={
            "value": 180,
            "unit": "mmol/L",
            "context": "random",
            "measured_at_ms": 1_760_000_000_000,
        },
    )
    assert invalid.status_code == 422


def test_temperature_demo_is_separate_from_real_evidence(client: TestClient, app) -> None:
    response = client.post("/api/v1/temperature-demo/start")
    assert response.status_code == 200
    assert response.json()["active"] is True

    now_ms = int(time() * 1000)
    with app.state.session_factory() as session:
        record_temperature_event(
            session,
            timestamp_ms=now_ms,
            side="right",
            zone="T4",
            raw_delta_c=3.0,
            corrected_delta_c=2.8,
            valid_zone_count=4,
            started_at_ms=now_ms - 8_000,
            source="demo",
            load_state="unloaded",
            motion_state="stationary",
        )

    assessment = client.get("/api/v1/assessment/latest").json()
    assert assessment["temperature"]["demo_days"] == 1
    assert assessment["temperature"]["real_days"] == 0
    assert assessment["temperature"]["status"] == "demo_single"
    assert assessment["rating"]["rating"] == "insufficient_data"
    records = client.get("/api/v1/temperature/daily").json()
    assert len(records) == 1
    assert all(item["source"] == "demo" for item in records)
    assert all(item["zone"] == "T4" for item in records)

    reset = client.post("/api/v1/temperature-demo/reset")
    assert reset.json()["active"] is False
    assert client.get("/api/v1/temperature/daily").json() == []


def test_real_temperature_single_day_is_one_of_two(client: TestClient, app) -> None:
    now_ms = 1_785_000_000_000
    with app.state.session_factory() as session:
        record_temperature_event(
            session,
            timestamp_ms=now_ms,
            side="right",
            zone="T4",
            raw_delta_c=-2.9,
            corrected_delta_c=-2.6,
            valid_zone_count=3,
            started_at_ms=now_ms - 15_000,
            source="device_observation",
            load_state="loaded",
            motion_state="stationary",
        )
    temperature = client.get("/api/v1/assessment/latest").json()["temperature"]
    assert temperature["real_days"] == 1
    assert temperature["real_consecutive_days"] == 1
    assert temperature["status"] == "single_day"


def test_rating_trend_compares_current_session_with_previous(app) -> None:
    with app.state.session_factory() as session:
        session.add(CalibrationState(
            state_key="personal_baseline",
            reset_after_frame_id=0,
            reset_at_ms=1_000,
        ))
        for index in range(20):
            session.add(_frame("left", index, 1_000 + index))
            session.add(_frame("right", index, 1_000 + index))
        session.add(RiskEvent(
            event_id="evt_previous_left",
            risk_type="left_load_bias",
            risk_side="left",
            risk_level=2,
            started_at_ms=1_100,
            duration_ms=10_000,
            status="resolved",
        ))
        session.commit()
        assert current_rating(session).rating == "attention"
        save_session_snapshot(session)

        state = session.get(CalibrationState, "personal_baseline")
        assert state is not None
        state.reset_at_ms = 5_000
        for index in range(20, 40):
            session.add(_frame("left", index, 5_000 + index))
            session.add(_frame("right", index, 5_000 + index))
        session.commit()

        summary = assessment_summary(session)
        assert summary.rating.rating == "normal"
        assert summary.rating.trend == "improving"
        assert summary.previous_rating is not None
        assert summary.previous_rating.rating == "attention"
