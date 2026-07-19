from __future__ import annotations

import json
import sys
from pathlib import Path
from time import time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.main import create_app
from backend.app.models import Command, InterventionFeedback, RiskEvent, SensorFrame
from backend.app.repositories.command_repository import create_command
from backend.app.schemas import DeviceCommand

def load_example(name: str) -> dict:
    return json.loads((ROOT / "protocol" / "examples" / name).read_text(encoding="utf-8"))


@pytest.fixture()
def app(tmp_path: Path):
    application = create_app(f"sqlite:///{(tmp_path / 'test.db').as_posix()}")
    yield application
    application.state.engine.dispose()


@pytest.fixture()
def client(app):
    with TestClient(app) as test_client:
        yield test_client


def sensor_batch() -> dict:
    return {
        "protocol_version": 1,
        "app_received_at_ms": 1760000000050,
        "frames": [load_example("left_frame.json"), load_example("right_frame.json")],
    }


def test_health(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_batch_accepts_and_persists_two_frames(client: TestClient, app) -> None:
    response = client.post("/api/v1/sensor/batch", json=sensor_batch())
    assert response.status_code == 200
    assert response.json() == {"accepted": 2, "rejected": 0, "latest_risk": "normal"}
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(SensorFrame)) == 2


def test_duplicate_batch_is_idempotently_rejected(client: TestClient) -> None:
    assert client.post("/api/v1/sensor/batch", json=sensor_batch()).json()["accepted"] == 2
    result = client.post("/api/v1/sensor/batch", json=sensor_batch()).json()
    assert result["accepted"] == 0
    assert result["rejected"] == 2


def test_invalid_frame_returns_422(client: TestClient) -> None:
    payload = sensor_batch()
    payload["frames"][0]["pressure"][0] = 1.5
    response = client.post("/api/v1/sensor/batch", json=payload)
    assert response.status_code == 422


def test_unknown_request_field_returns_422(client: TestClient) -> None:
    payload = sensor_batch()
    payload["unexpected"] = True
    assert client.post("/api/v1/sensor/batch", json=payload).status_code == 422


def test_realtime_before_data_is_incomplete(client: TestClient) -> None:
    result = client.get("/api/v1/realtime").json()
    assert result["left"] is None
    assert result["right"] is None
    assert result["risk"]["risk_type"] == "data_incomplete"


def test_realtime_pairs_same_sync_id(client: TestClient) -> None:
    client.post("/api/v1/sensor/batch", json=sensor_batch())
    response = client.get("/api/v1/realtime")
    assert response.status_code == 200
    result = response.json()
    assert result["sync_error_ms"] == 20
    assert result["paired_timestamp_ms"] == 1760000000020
    assert result["load_diff"] == pytest.approx(0.06 / 2.94)
    assert result["risk"]["risk_type"] == "normal"
    assert len(result["regional_analysis"]["left_pressure_scores"]) == 6
    assert len(result["regional_analysis"]["temperature_delta_c"]) == 4


def test_realtime_rejects_mismatched_sync_id(client: TestClient) -> None:
    payload = sensor_batch()
    payload["frames"][1]["sync_id"] = 2
    client.post("/api/v1/sensor/batch", json=payload)
    result = client.get("/api/v1/realtime").json()
    assert result["risk"]["risk_type"] == "data_incomplete"
    assert result["load_bias"] is None


def test_events_are_returned_newest_first(client: TestClient, app) -> None:
    with app.state.session_factory() as session:
        session.add_all(
            [
                RiskEvent(event_id="evt_1", risk_type="left_load_bias", risk_side="left", risk_level=1, started_at_ms=10, ended_at_ms=None, duration_ms=0, status="active"),
                RiskEvent(event_id="evt_2", risk_type="right_load_bias", risk_side="right", risk_level=2, started_at_ms=20, ended_at_ms=30, duration_ms=10, status="resolved"),
            ]
        )
        session.commit()
    result = client.get("/api/v1/events?limit=1").json()
    assert [event["event_id"] for event in result] == ["evt_2"]


def add_command(app, *, command_id: str = "cmd_test_1", expire_offset_ms: int = 60_000) -> None:
    now_ms = int(time() * 1000)
    payload = DeviceCommand(
        command_id=command_id,
        target="left",
        pattern="double",
        duration_ms=600,
        expire_at_ms=now_ms + expire_offset_ms,
        reason_code="left_load_bias",
    )
    with app.state.session_factory() as session:
        create_command(session, payload, now_ms)


def test_pending_command_is_returned(client: TestClient, app) -> None:
    add_command(app)
    result = client.get("/api/v1/command/pending?target=left").json()
    assert result["command"]["command_id"] == "cmd_test_1"


def test_expired_command_is_not_returned(client: TestClient, app) -> None:
    add_command(app, expire_offset_ms=-1)
    assert client.get("/api/v1/command/pending?target=left").json() == {"command": None}
    with app.state.session_factory() as session:
        assert session.get(Command, "cmd_test_1").status == "expired"


def test_ack_updates_command_and_replay_is_idempotent(client: TestClient, app) -> None:
    add_command(app)
    now_ms = int(time() * 1000)
    payload = {
        "protocol_version": 1,
        "command_id": "cmd_test_1",
        "device_id": "foot_left_001",
        "status": "executed",
        "ack_at_ms": now_ms,
        "executed_at_ms": now_ms,
        "error_code": "none",
    }
    assert client.post("/api/v1/ack", json=payload).json() == {"recorded": True}
    assert client.post("/api/v1/ack", json=payload).json() == {"recorded": True}
    with app.state.session_factory() as session:
        assert session.get(Command, "cmd_test_1").status == "executed"


def test_ack_unknown_command_returns_404(client: TestClient) -> None:
    now_ms = int(time() * 1000)
    response = client.post(
        "/api/v1/ack",
        json={
            "protocol_version": 1,
            "command_id": "cmd_unknown",
            "device_id": "foot_left_001",
            "status": "failed",
            "ack_at_ms": now_ms,
            "executed_at_ms": None,
            "error_code": "motor_fault",
        },
    )
    assert response.status_code == 404


def test_feedback_is_persisted(client: TestClient, app) -> None:
    response = client.post(
        "/api/v1/intervention/feedback",
        json={
            "event_id": "evt_1",
            "user_action": "followed_vibration",
            "effect_label": "effective",
            "before_load_diff": 1.2,
            "after_load_diff": 0.3,
            "recovery_time_ms": 2500,
        },
    )
    assert response.status_code == 201
    assert response.json() == {"recorded": True}
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(InterventionFeedback)) == 1
