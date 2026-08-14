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
    assert abs(response.json()["server_time_ms"] - int(time() * 1000)) < 1_000


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


def test_offline_sync_is_idempotent_and_archives_all_pairs(
    client: TestClient, app
) -> None:
    payload = sensor_batch()
    frames = []
    for index in range(3):
        for source in payload["frames"]:
            frame = dict(source)
            frame["packet_seq"] = source["packet_seq"] + index
            frame["timestamp_ms"] = source["timestamp_ms"] + index * 200
            frames.append(frame)
    body = {
        "protocol_version": 1,
        "app_received_at_ms": frames[-1]["timestamp_ms"],
        "frames": frames,
    }
    response = client.post("/api/v1/sensor/offline-sync", json=body)
    assert response.status_code == 200
    assert response.json()["accepted"] == 6
    duplicate = client.post("/api/v1/sensor/offline-sync", json=body).json()
    assert duplicate["accepted"] == 0
    assert duplicate["rejected"] == 6
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(SensorFrame)) == 6


def test_offline_sync_rejects_duplicates_inside_one_request(
    client: TestClient, app
) -> None:
    payload = sensor_batch()
    payload["frames"] = payload["frames"] + payload["frames"]

    response = client.post("/api/v1/sensor/offline-sync", json=payload)

    assert response.status_code == 200
    assert response.json()["accepted"] == 2
    assert response.json()["rejected"] == 2
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(SensorFrame)) == 2


def test_offline_sync_does_not_rewrite_existing_risk_events(
    client: TestClient, app
) -> None:
    event = RiskEvent(
        event_id="evt_existing",
        risk_type="left_load_bias",
        risk_side="left",
        risk_level=2,
        started_at_ms=1760000005000,
        ended_at_ms=1760000015000,
        duration_ms=10000,
        status="recovered",
        risk_components_json="[]",
    )
    with app.state.session_factory() as session:
        session.add(event)
        session.commit()

    payload = sensor_batch()
    for frame in payload["frames"]:
        frame["timestamp_ms"] -= 60_000
    response = client.post("/api/v1/sensor/offline-sync", json=payload)

    assert response.status_code == 200
    with app.state.session_factory() as session:
        stored = session.get(RiskEvent, "evt_existing")
        assert stored is not None
        assert stored.started_at_ms == 1760000005000
        assert stored.ended_at_ms == 1760000015000
        assert stored.duration_ms == 10000
        assert stored.status == "recovered"
        assert session.scalar(select(func.count()).select_from(RiskEvent)) == 1


def test_session_summary_and_csv_exports_work_without_live_data(
    client: TestClient,
) -> None:
    assert client.post("/api/v1/sensor/batch", json=sensor_batch()).status_code == 200
    summary = client.get("/api/v1/session/latest")
    assert summary.status_code == 200
    assert summary.json()["session_status"] == "recent"
    assert summary.json()["left_valid_pressure_channels"] == 6
    assert summary.json()["right_valid_pressure_channels"] == 6

    advice = client.post("/api/v1/ai/session-advice")
    assert advice.status_code == 200
    assert advice.json()["session_status"] == "recent"
    assert "当前无实时数据" in advice.json()["advice"]

    events_csv = client.get("/api/v1/export/events.csv")
    session_csv = client.get("/api/v1/export/session.csv")
    assert events_csv.status_code == 200
    assert events_csv.text.startswith("event_id,risk_type")
    assert session_csv.status_code == 200
    assert session_csv.text.startswith(
        "timestamp_ms,left_total_pressure,right_total_pressure"
    )


def test_offline_intervention_sync_is_idempotent(
    client: TestClient, app
) -> None:
    payload = {
        "protocol_version": 1,
        "records": [{
            "event_id": "local_evt_1760000000000",
            "command": {
                "protocol_version": 1,
                "command_id": "cmd_local_1760000000000",
                "target": "both",
                "pattern": "long",
                "duration_ms": 1500,
                "expire_at_ms": 1760000030000,
                "reason_code": "forefoot_high",
            },
            "risk": {
                "risk_type": "forefoot_high",
                "risk_side": "left",
                "risk_level": 2,
                "duration_ms": 4200,
            },
            "active_risks": [{
                "risk_type": "forefoot_high",
                "risk_side": "left",
                "risk_level": 2,
                "duration_ms": 4200,
            }],
            "started_at_ms": 1759999995800,
            "acknowledgements": [
                {
                    "protocol_version": 1,
                    "command_id": "cmd_local_1760000000000",
                    "device_id": "foot_left_001",
                    "status": "executed",
                    "ack_at_ms": 1760000000100,
                    "executed_at_ms": 1760000000050,
                    "error_code": "none",
                },
                {
                    "protocol_version": 1,
                    "command_id": "cmd_local_1760000000000",
                    "device_id": "foot_right_001",
                    "status": "executed",
                    "ack_at_ms": 1760000000120,
                    "executed_at_ms": 1760000000060,
                    "error_code": "none",
                },
            ],
            "before_load_diff": 0.40,
            "after_load_diff": 0.10,
            "effect_label": "effective",
            "recovery_time_ms": 15000,
        }],
    }
    first = client.post("/api/v1/sensor/offline-interventions", json=payload)
    assert first.status_code == 200
    assert first.json() == {"accepted": 1, "rejected": 0}
    second = client.post("/api/v1/sensor/offline-interventions", json=payload)
    assert second.json() == {"accepted": 0, "rejected": 1}
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(Command)) == 1
        assert session.scalar(select(func.count()).select_from(InterventionFeedback)) == 1


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


def test_calibration_status_and_reset_start_a_new_learning_window(
    client: TestClient,
) -> None:
    initial_status = client.get("/api/v1/calibration/status")
    assert initial_status.status_code == 200
    assert initial_status.json()["baseline_ready"] is False
    assert initial_status.json()["sample_count"] == 0

    base = sensor_batch()
    for index in range(40):
        frames = []
        for source in base["frames"]:
            frame = dict(source)
            frame["packet_seq"] = source["packet_seq"] + index
            frame["timestamp_ms"] = source["timestamp_ms"] + index * 200
            frames.append(frame)
        response = client.post(
            "/api/v1/sensor/batch",
            json={
                "protocol_version": 1,
                "app_received_at_ms": max(
                    frame["timestamp_ms"] for frame in frames
                ),
                "frames": frames,
            },
        )
        assert response.status_code == 200

    learned = client.get("/api/v1/calibration/status").json()
    assert learned["baseline_ready"] is True
    assert learned["sample_count"] == learned["required_samples"]

    now_ms = int(time() * 1000)
    with client.app.state.session_factory() as session:
        event = RiskEvent(
            event_id="evt_calibration_reset",
            risk_type="left_load_bias",
            risk_side="left",
            risk_level=2,
            started_at_ms=now_ms - 1_000,
            ended_at_ms=None,
            duration_ms=1_000,
            before_load_diff=0.4,
            after_load_diff=None,
            status="active",
        )
        session.add(event)
        session.commit()
        create_command(
            session,
            DeviceCommand(
                command_id="cmd_calibration_reset",
                target="left",
                pattern="double",
                duration_ms=800,
                expire_at_ms=now_ms + 30_000,
                reason_code="left_load_bias",
            ),
            now_ms,
            event_id=event.event_id,
        )

    reset = client.post("/api/v1/calibration/reset")
    assert reset.status_code == 200
    assert reset.json()["baseline_ready"] is False
    assert reset.json()["sample_count"] == 0
    assert reset.json()["reset_at_ms"] is not None

    current = client.get("/api/v1/calibration/status").json()
    assert current == reset.json()
    with client.app.state.session_factory() as session:
        interrupted_event = session.get(RiskEvent, "evt_calibration_reset")
        expired_command = session.get(Command, "cmd_calibration_reset")
        assert interrupted_event.status == "interrupted"
        assert interrupted_event.ended_at_ms is not None
        assert expired_command.status == "expired"
        assert expired_command.error_code == "command_expired"


def test_realtime_rejects_mismatched_sync_id(client: TestClient) -> None:
    payload = sensor_batch()
    payload["frames"][1]["sync_id"] = 2
    client.post("/api/v1/sensor/batch", json=payload)
    result = client.get("/api/v1/realtime").json()
    assert result["risk"]["risk_type"] == "data_incomplete"
    assert result["load_bias"] is None


def test_realtime_holds_recent_complete_pair_during_brief_side_skew(
    client: TestClient,
) -> None:
    initial = sensor_batch()
    client.post("/api/v1/sensor/batch", json=initial)

    initial_packet_seq = initial["frames"][0]["packet_seq"]
    next_left = dict(initial["frames"][0])
    next_left["packet_seq"] = initial_packet_seq + 1
    next_left["timestamp_ms"] += 200
    response = client.post(
        "/api/v1/sensor/batch",
        json={
            "protocol_version": 1,
            "app_received_at_ms": next_left["timestamp_ms"],
            "frames": [next_left],
        },
    )

    assert response.status_code == 200
    assert response.json()["latest_risk"] == "normal"
    realtime = client.get("/api/v1/realtime").json()
    assert realtime["risk"]["risk_type"] == "normal"
    assert realtime["left"]["packet_seq"] == initial_packet_seq
    assert realtime["right"]["packet_seq"] == initial_packet_seq
    assert realtime["paired_timestamp_ms"] == 1760000000020


def test_realtime_reports_incomplete_after_side_skew_exceeds_continuity_gap(
    client: TestClient,
) -> None:
    initial = sensor_batch()
    client.post("/api/v1/sensor/batch", json=initial)

    stale_left = dict(initial["frames"][0])
    stale_left["packet_seq"] = 6
    stale_left["timestamp_ms"] += 1_200
    response = client.post(
        "/api/v1/sensor/batch",
        json={
            "protocol_version": 1,
            "app_received_at_ms": stale_left["timestamp_ms"],
            "frames": [stale_left],
        },
    )

    assert response.status_code == 200
    assert response.json()["latest_risk"] == "data_incomplete"
    realtime = client.get("/api/v1/realtime").json()
    assert realtime["risk"]["risk_type"] == "data_incomplete"
    assert realtime["paired_timestamp_ms"] is None


@pytest.mark.parametrize(
    ("temperature_index", "invalid_flag"),
    [
        pytest.param(0, 0x00000040, id="T1"),
        pytest.param(1, 0x00000080, id="T2"),
        pytest.param(2, 0x00000100, id="T3"),
        pytest.param(3, 0x00000200, id="T4"),
    ],
)
def test_temperature_invalid_flag_only_degrades_that_channel(
    temperature_index: int,
    invalid_flag: int,
    client: TestClient,
) -> None:
    payload = sensor_batch()
    payload["frames"][0]["temperature"][temperature_index] = 0.0
    payload["frames"][0]["quality_flags"] = invalid_flag

    response = client.post("/api/v1/sensor/batch", json=payload)
    assert response.status_code == 200
    assert response.json()["latest_risk"] == "normal"

    realtime = client.get("/api/v1/realtime").json()
    assert realtime["risk"]["risk_type"] == "normal"
    assert realtime["pressure_available"] is True
    assert realtime["regional_analysis"] is not None
    assert realtime["regional_analysis"]["temperature_delta_c"][temperature_index] is None
    assert realtime["regional_analysis"]["left_temperature_valid"][temperature_index] is False


def test_low_battery_does_not_block_pressure_or_temperature_pairing(
    client: TestClient,
) -> None:
    payload = sensor_batch()
    payload["frames"][0]["quality_flags"] = 0x00001000

    response = client.post("/api/v1/sensor/batch", json=payload)
    assert response.status_code == 200
    assert response.json()["latest_risk"] == "normal"

    realtime = client.get("/api/v1/realtime").json()
    assert realtime["risk"]["risk_type"] == "normal"
    assert realtime["paired_timestamp_ms"] == 1760000000020
    assert realtime["regional_analysis"] is not None


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


def test_backend_restart_expires_pending_commands(tmp_path: Path) -> None:
    database_path = tmp_path / "restart-command.db"
    database_url = f"sqlite:///{database_path.as_posix()}"
    first_app = create_app(database_url)
    now_ms = int(time() * 1000)
    with first_app.state.session_factory() as session:
        create_command(
            session,
            DeviceCommand(
                command_id="cmd_before_restart",
                target="left",
                pattern="double",
                duration_ms=800,
                expire_at_ms=now_ms + 30_000,
                reason_code="manual_test",
            ),
            now_ms,
        )
    first_app.state.engine.dispose()

    restarted_app = create_app(database_url)
    try:
        with restarted_app.state.session_factory() as session:
            command = session.get(Command, "cmd_before_restart")
            assert command is not None
            assert command.status == "expired"
            assert command.error_code == "command_expired"
    finally:
        restarted_app.state.engine.dispose()


def test_calibration_profile_survives_backend_restart(tmp_path: Path) -> None:
    database_path = tmp_path / "restart-calibration.db"
    database_url = f"sqlite:///{database_path.as_posix()}"
    first_app = create_app(database_url)
    with TestClient(first_app) as client:
        base = sensor_batch()
        for index in range(40):
            frames = []
            for source in base["frames"]:
                frame = dict(source)
                frame["packet_seq"] = source["packet_seq"] + index
                frame["timestamp_ms"] = source["timestamp_ms"] + index * 200
                frames.append(frame)
            response = client.post(
                "/api/v1/sensor/batch",
                json={
                    "protocol_version": 1,
                    "app_received_at_ms": frames[-1]["timestamp_ms"],
                    "frames": frames,
                },
            )
            assert response.status_code == 200
        assert client.get("/api/v1/calibration/status").json()["baseline_ready"] is True
    first_app.state.engine.dispose()

    restarted_app = create_app(database_url)
    try:
        with TestClient(restarted_app) as client:
            status = client.get("/api/v1/calibration/status").json()
            assert status["baseline_ready"] is True
            assert status["sample_count"] == 40
    finally:
        restarted_app.state.engine.dispose()


def test_saved_baseline_is_rejected_when_device_pair_changes(
    client: TestClient,
) -> None:
    base = sensor_batch()
    for index in range(40):
        frames = []
        for source in base["frames"]:
            frame = dict(source)
            frame["packet_seq"] = source["packet_seq"] + index
            frame["timestamp_ms"] = source["timestamp_ms"] + index * 200
            frames.append(frame)
        assert client.post(
            "/api/v1/sensor/batch",
            json={
                "protocol_version": 1,
                "app_received_at_ms": frames[-1]["timestamp_ms"],
                "frames": frames,
            },
        ).status_code == 200
    assert client.get("/api/v1/calibration/status").json()["baseline_ready"] is True

    changed_frames = []
    for source in base["frames"]:
        frame = dict(source)
        frame["device_id"] = f"new_{frame['side']}"
        frame["packet_seq"] += 100
        frame["timestamp_ms"] += 100_000
        changed_frames.append(frame)
    assert client.post(
        "/api/v1/sensor/batch",
        json={
            "protocol_version": 1,
            "app_received_at_ms": changed_frames[-1]["timestamp_ms"],
            "frames": changed_frames,
        },
    ).status_code == 200

    status = client.get("/api/v1/calibration/status").json()
    assert status["baseline_ready"] is False
    assert status["sample_count"] == 1


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


def test_bilateral_ack_waits_for_both_devices(client: TestClient, app) -> None:
    now_ms = int(time() * 1000)
    payload = DeviceCommand(
        command_id="cmd_test_both",
        target="both",
        pattern="long",
        duration_ms=1_500,
        expire_at_ms=now_ms + 60_000,
        reason_code="forefoot_high",
    )
    with app.state.session_factory() as session:
        create_command(session, payload, now_ms)

    def ack(device_id: str) -> dict:
        return {
            "protocol_version": 1,
            "command_id": "cmd_test_both",
            "device_id": device_id,
            "status": "executed",
            "ack_at_ms": now_ms + 100,
            "executed_at_ms": now_ms + 100,
            "error_code": "none",
        }

    assert client.post("/api/v1/ack", json=ack("foot_left_001")).status_code == 200
    with app.state.session_factory() as session:
        assert session.get(Command, "cmd_test_both").status == "pending"

    assert client.post("/api/v1/ack", json=ack("foot_right_001")).status_code == 200
    with app.state.session_factory() as session:
        command = session.get(Command, "cmd_test_both")
        assert command.status == "executed"
        assert command.executed_at_ms == now_ms + 100


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
    with app.state.session_factory() as session:
        session.add(
            RiskEvent(
                event_id="evt_1",
                risk_type="left_load_bias",
                risk_side="left",
                risk_level=2,
                started_at_ms=1_000,
                ended_at_ms=4_000,
                duration_ms=3_000,
                before_load_diff=1.2,
                after_load_diff=0.3,
                status="resolved",
            )
        )
        session.commit()

    response = client.post(
        "/api/v1/intervention/feedback",
        json={
            "event_id": "evt_1",
            "user_action": "followed_vibration",
            "effect_label": "effective",
            "before_load_diff": 1.2,
            "after_load_diff": 0.1,
            "recovery_time_ms": 2500,
        },
    )
    assert response.status_code == 201
    assert response.json() == {"recorded": True}
    with app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(InterventionFeedback)) == 1

    event = client.get("/api/v1/events").json()[0]
    assert event["intervention_action"] == "followed_vibration"
    assert event["effect_label"] == "effective"
    assert event["before_load_diff"] == 1.2
    assert event["after_load_diff"] == 0.1
    assert event["recovery_time_ms"] == 2_500
