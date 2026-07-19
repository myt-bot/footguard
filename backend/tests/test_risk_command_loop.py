from __future__ import annotations

import csv
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
from backend.app.models import Command, CommandAck, InterventionFeedback, RiskEvent

SAMPLE_DATA = ROOT / "sample_data"


@pytest.fixture()
def app(tmp_path: Path):
    application = create_app(f"sqlite:///{(tmp_path / 'risk-test.db').as_posix()}")
    yield application
    application.state.engine.dispose()


@pytest.fixture()
def client(app):
    with TestClient(app) as test_client:
        yield test_client


def scenario_frames(name: str) -> list[dict]:
    frames = []
    with (SAMPLE_DATA / f"{name}.csv").open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            frames.append(
                {
                    "protocol_version": int(row["protocol_version"]),
                    "sensor_layout_version": row["sensor_layout_version"],
                    "device_id": row["device_id"],
                    "side": row["side"],
                    "sync_id": int(row["sync_id"]),
                    "packet_seq": int(row["packet_seq"]),
                    "timestamp_ms": int(row["timestamp_ms"]),
                    "pressure": [float(row[f"p{i}"]) for i in range(1, 7)],
                    "temperature": [float(row[f"t{i}"]) for i in range(1, 5)],
                    "imu": {name: float(row[name]) for name in ("ax", "ay", "az", "gx", "gy", "gz")},
                    "battery": int(row["battery"]),
                    "quality_flags": int(row["quality_flags"]),
                    "source": row["source"],
                }
            )
    return frames


def upload(client: TestClient, frames: list[dict]) -> dict:
    response = client.post(
        "/api/v1/sensor/batch",
        json={
            "protocol_version": 1,
            "app_received_at_ms": int(time() * 1000),
            "frames": frames,
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize("scenario", ["normal_stand", "normal_walk"])
def test_normal_scenarios_do_not_create_alarm_or_motor_command(
    scenario: str, client: TestClient, app
) -> None:
    result = upload(client, scenario_frames(scenario))
    assert result["latest_risk"] == "normal"
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(RiskEvent)) == 0
        assert session.scalar(select(func.count()).select_from(Command)) == 0


@pytest.mark.parametrize(
    ("scenario", "risk_type", "side"),
    [
        ("left_load_bias", "left_load_bias", "left"),
        ("right_load_bias", "right_load_bias", "right"),
        ("left_forefoot_high", "forefoot_high", "left"),
        ("left_temperature_rise", "temperature_asymmetry", "left"),
    ],
)
def test_sustained_risk_creates_one_event_and_motor_vibration_command(
    scenario: str, risk_type: str, side: str, client: TestClient, app
) -> None:
    result = upload(client, scenario_frames(scenario))
    assert result["latest_risk"] == risk_type
    with app.state.session_factory() as session:
        event = session.scalar(select(RiskEvent))
        command = session.scalar(select(Command))
        assert event.risk_level == 3
        assert event.risk_side == side
        assert command.event_id == event.event_id
        assert command.target == side
        assert command.pattern == "double"
        assert command.duration_ms == 800
        assert command.reason_code == risk_type


def test_disconnect_is_data_incomplete_and_never_vibrates(client: TestClient, app) -> None:
    result = upload(client, scenario_frames("right_disconnect"))
    assert result["latest_risk"] == "data_incomplete"
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(Command)) == 0


def test_pressure_risk_is_invariant_to_overall_weight_scale(
    client: TestClient,
) -> None:
    frames = scenario_frames("left_load_bias")
    for frame in frames:
        frame["pressure"] = [round(value * 0.55, 4) for value in frame["pressure"]]
    result = upload(client, frames)
    assert result["latest_risk"] == "left_load_bias"
    realtime = client.get("/api/v1/realtime").json()
    assert realtime["load_bias"] > 0.25


def test_stable_pairs_build_personal_baseline(client: TestClient) -> None:
    upload(client, scenario_frames("normal_stand"))
    analysis = client.get("/api/v1/realtime").json()["regional_analysis"]
    assert analysis["baseline_ready"] is True
    assert analysis["baseline_source"] == "personal"
    assert len(analysis["left_temperature_scores"]) == 4


def test_replaying_same_risk_does_not_duplicate_event_or_command(client: TestClient, app) -> None:
    frames = scenario_frames("left_load_bias")
    upload(client, frames)
    upload(client, frames)
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(RiskEvent)) == 1
        assert session.scalar(select(func.count()).select_from(Command)) == 1


def test_new_sync_window_creates_a_new_motor_reminder(
    client: TestClient,
    app,
) -> None:
    first_episode = scenario_frames("left_load_bias")
    upload(client, first_episode)
    with app.state.session_factory() as session:
        first_command = session.scalar(select(Command))
        first_command.status = "expired"
        session.commit()

    second_episode = scenario_frames("left_load_bias")
    for frame in second_episode:
        frame["sync_id"] += 100
        frame["timestamp_ms"] += 1_000_000
    upload(client, second_episode)

    with app.state.session_factory() as session:
        events = list(session.scalars(select(RiskEvent)))
        commands = list(session.scalars(select(Command)))
        assert len(events) == 2
        assert len(commands) == 2
        assert sum(command.status == "pending" for command in commands) == 1


def test_expired_motor_command_cannot_be_acknowledged_as_executed(client: TestClient, app) -> None:
    upload(client, scenario_frames("left_load_bias"))
    with app.state.session_factory() as session:
        command = session.scalar(select(Command))
        command.expire_at_ms = int(time() * 1000) - 1
        session.commit()
        command_id = command.command_id
    now_ms = int(time() * 1000)
    response = client.post(
        "/api/v1/ack",
        json={
            "protocol_version": 1,
            "command_id": command_id,
            "device_id": "foot_left_001",
            "status": "executed",
            "ack_at_ms": now_ms,
            "executed_at_ms": now_ms,
            "error_code": "none",
        },
    )
    assert response.status_code == 409


def test_duplicate_motor_ack_is_idempotent(client: TestClient, app) -> None:
    upload(client, scenario_frames("left_load_bias"))
    command = client.get("/api/v1/command/pending?target=left").json()["command"]
    now_ms = int(time() * 1000)
    ack = {
        "protocol_version": 1,
        "command_id": command["command_id"],
        "device_id": "foot_left_001",
        "status": "executed",
        "ack_at_ms": now_ms,
        "executed_at_ms": now_ms,
        "error_code": "none",
    }
    assert client.post("/api/v1/ack", json=ack).status_code == 200
    assert client.post("/api/v1/ack", json=ack).status_code == 200
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(CommandAck)) == 1


def test_intervention_recovery_records_motor_effect(client: TestClient, app) -> None:
    frames = scenario_frames("intervention_recovery")
    split = 130  # first 13 seconds contain the sustained-bias phase
    upload(client, frames[:split])
    pending = client.get("/api/v1/command/pending?target=left").json()["command"]
    assert pending["pattern"] == "double"
    now_ms = int(time() * 1000)
    ack = {
        "protocol_version": 1,
        "command_id": pending["command_id"],
        "device_id": "foot_left_001",
        "status": "executed",
        "ack_at_ms": now_ms,
        "executed_at_ms": now_ms,
        "error_code": "none",
    }
    assert client.post("/api/v1/ack", json=ack).status_code == 200
    upload(client, frames[split:])
    with app.state.session_factory() as session:
        event = session.scalar(select(RiskEvent))
        feedback = session.scalar(select(InterventionFeedback))
        assert event.status == "resolved"
        assert feedback.user_action == "motor_vibration"
        assert feedback.effect_label == "effective"
        assert feedback.after_load_diff < feedback.before_load_diff
