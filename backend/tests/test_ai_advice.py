from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.main import create_app


@pytest.fixture()
def client(tmp_path: Path):
    application = create_app(f"sqlite:///{(tmp_path / 'test.db').as_posix()}")
    with TestClient(application) as test_client:
        yield test_client
    application.state.engine.dispose()


def advice_payload(
    *,
    risk_type: str,
    risk_side: str,
    risk_level: int,
    duration_ms: int = 6000,
) -> dict:
    return {
        "protocol_version": 1,
        "risk": {
            "risk_type": risk_type,
            "risk_side": risk_side,
            "risk_level": risk_level,
            "duration_ms": duration_ms,
        },
        "load_diff": None,
        "temperature_delta_max_c": None,
        "baseline_ready": True,
    }


def test_normal_advice_never_proposes_motor_action(client: TestClient) -> None:
    response = client.post(
        "/api/v1/ai/advice",
        json=advice_payload(
            risk_type="normal",
            risk_side="none",
            risk_level=0,
            duration_ms=0,
        ),
    )

    assert response.status_code == 200
    result = response.json()
    assert result["provider"] == "mock-risk-advisor-v1"
    assert result["target"] == "none"
    assert result["candidate_pattern"] == "off"


def test_severe_left_bias_returns_explanation_and_candidate(
    client: TestClient,
) -> None:
    payload = advice_payload(
        risk_type="left_load_bias",
        risk_side="left",
        risk_level=2,
    )
    payload["load_diff"] = 0.31

    response = client.post("/api/v1/ai/advice", json=payload)

    assert response.status_code == 200
    result = response.json()
    assert result["risk_level"] == 2
    assert result["target"] == "left"
    assert result["candidate_pattern"] == "double"
    assert "0.310" in result["explanation"]
    assert "不能替代医疗诊断" in result["advice"]


def test_incomplete_data_only_recommends_connection_check(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/ai/advice",
        json=advice_payload(
            risk_type="data_incomplete",
            risk_side="none",
            risk_level=0,
            duration_ms=0,
        ),
    )

    assert response.status_code == 200
    result = response.json()
    assert result["target"] == "none"
    assert result["candidate_pattern"] == "off"
    assert "检查左右脚设备连接" in result["advice"]


def test_inconsistent_risk_side_cannot_propose_motor_action(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/ai/advice",
        json=advice_payload(
            risk_type="left_load_bias",
            risk_side="right",
            risk_level=3,
        ),
    )

    assert response.status_code == 200
    result = response.json()
    assert result["target"] == "none"
    assert result["candidate_pattern"] == "off"


def test_unknown_request_field_returns_422(client: TestClient) -> None:
    payload = advice_payload(
        risk_type="temperature_asymmetry",
        risk_side="left",
        risk_level=2,
    )
    payload["unexpected"] = True

    assert client.post("/api/v1/ai/advice", json=payload).status_code == 422
