from __future__ import annotations

import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.main import create_app
from backend.app.schemas import (
    AiAdviceRequest,
    AiChatRequest,
    AiQuestionRequest,
    RiskImprovementSummary,
    SessionSummary,
)
from backend.app.services.ai_advisor_service import (
    generate_advice,
    generate_chat_answer,
    generate_question_answer,
    generate_session_advice,
)


@pytest.fixture(autouse=True)
def clear_ai_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "FOOTGUARD_AI_PROVIDER",
        "FOOTGUARD_AI_BASE_URL",
        "FOOTGUARD_AI_API_KEY",
        "FOOTGUARD_AI_MODEL",
        "FOOTGUARD_AI_TIMEOUT_SECONDS",
    ):
        monkeypatch.delenv(name, raising=False)


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


def test_level_two_left_bias_returns_explanation_without_motor_candidate(
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
    assert result["target"] == "none"
    assert result["candidate_pattern"] == "off"
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


def test_persistent_risk_proposes_long_pattern(client: TestClient) -> None:
    response = client.post(
        "/api/v1/ai/advice",
        json=advice_payload(
            risk_type="forefoot_high",
            risk_side="left",
            risk_level=3,
            duration_ms=11_000,
        ),
    )

    assert response.status_code == 200
    result = response.json()
    assert result["target"] == "left"
    assert result["candidate_pattern"] == "long"


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


def test_fixed_question_returns_contextual_safe_answer(client: TestClient) -> None:
    payload = advice_payload(
        risk_type="temperature_asymmetry",
        risk_side="left",
        risk_level=2,
    )
    payload["temperature_delta_max_c"] = 2.7
    payload["question_key"] = "improvement_check"

    response = client.post("/api/v1/ai/question", json=payload)

    assert response.status_code == 200
    result = response.json()
    assert result["question_key"] == "improvement_check"
    assert result["question"] == "怎样判断已经改善？"
    assert "同一区域温差" in result["answer"]
    assert "不能替代医疗诊断" in result["answer"]


def test_question_endpoint_rejects_arbitrary_user_prompt(
    client: TestClient,
) -> None:
    payload = advice_payload(
        risk_type="normal",
        risk_side="none",
        risk_level=0,
        duration_ms=0,
    )
    payload["question_key"] = "write_any_diagnosis"

    assert client.post("/api/v1/ai/question", json=payload).status_code == 422


def test_free_chat_works_during_normal_pressure_with_temperature_unavailable(
    client: TestClient,
) -> None:
    payload = advice_payload(
        risk_type="normal",
        risk_side="none",
        risk_level=0,
        duration_ms=0,
    )
    payload.update(
        {
            "question": "现在的状态怎么样？",
            "pressure_available": True,
            "temperature_available": False,
            "valid_temperature_pairs": 0,
            "motion_state": "stationary",
            "left_connected": True,
            "right_connected": True,
        }
    )

    response = client.post("/api/v1/ai/chat", json=payload)

    assert response.status_code == 200
    result = response.json()
    assert result["question"] == "现在的状态怎么样？"
    assert "不影响压力监测" in result["answer"]
    assert "不能替代医疗诊断" in result["answer"]


def test_free_chat_explains_wearing_calibration() -> None:
    payload = advice_payload(
        risk_type="normal",
        risk_side="none",
        risk_level=0,
        duration_ms=0,
    )
    payload.update(
        {
            "question": "为什么还没开始判断？",
            "baseline_ready": False,
            "pressure_available": True,
            "temperature_available": True,
            "valid_temperature_pairs": 4,
            "motion_state": "stationary",
            "left_connected": True,
            "right_connected": True,
        }
    )
    result = generate_chat_answer(AiChatRequest.model_validate(payload))
    assert "本次穿戴基线" in result.answer


def test_session_advice_prioritizes_evidence_instead_of_replaying_events() -> None:
    summary = SessionSummary(
        session_status="live",
        baseline_ready=True,
        event_count=5,
        highest_risk_level=3,
        risk_counts={"left_load_bias": 3, "forefoot_high": 2},
        motor_executed_count=4,
        improvement_summary=[
            RiskImprovementSummary(
                risk_type="left_load_bias",
                risk_side="left",
                evaluated_count=3,
                effective_count=2,
                ineffective_count=1,
                median_improvement_ratio=0.42,
                metric_unit="ratio",
            )
        ],
        left_valid_pressure_channels=6,
        right_valid_pressure_channels=6,
        temperature_valid_pairs=4,
    )

    result = generate_session_advice(summary)

    assert "结论：" in result.advice
    assert "依据：" in result.advice
    assert "行动：" in result.advice
    assert "数据限制：" in result.advice
    assert "记录 5 次风险事件" in result.advice


def test_configured_cloud_provider_returns_narrative_but_local_motor_candidate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FOOTGUARD_AI_PROVIDER", "openai_compatible")
    monkeypatch.setenv("FOOTGUARD_AI_BASE_URL", "https://model.example/v1")
    monkeypatch.setenv("FOOTGUARD_AI_API_KEY", "test-secret")
    monkeypatch.setenv("FOOTGUARD_AI_MODEL", "competition-model")
    payload = advice_payload(
        risk_type="left_load_bias",
        risk_side="left",
        risk_level=2,
    )

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url == "https://model.example/v1/chat/completions"
        assert request.headers["authorization"] == "Bearer test-secret"
        request_body = __import__("json").loads(request.content)
        assert request_body["model"] == "competition-model"
        assert "target" not in request_body
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": (
                                '{"explanation":"左脚负荷持续偏高。",'
                                '"advice":"请调整站姿并观察。"}'
                            )
                        }
                    }
                ]
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as cloud_client:
        result = generate_advice(
            AiAdviceRequest.model_validate(payload),
            client=cloud_client,
        )

    assert result.provider == "openai-compatible:competition-model"
    assert result.explanation == "左脚负荷持续偏高。"
    assert "不能替代医疗诊断" in result.advice
    assert result.target == "none"
    assert result.candidate_pattern == "off"


def test_cloud_failure_falls_back_to_safe_mock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FOOTGUARD_AI_PROVIDER", "openai_compatible")
    monkeypatch.setenv("FOOTGUARD_AI_API_KEY", "test-secret")
    monkeypatch.setenv("FOOTGUARD_AI_MODEL", "competition-model")
    payload = advice_payload(
        risk_type="temperature_asymmetry",
        risk_side="right",
        risk_level=2,
    )

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, json={"error": "temporarily unavailable"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as cloud_client:
        result = generate_advice(
            AiAdviceRequest.model_validate(payload),
            client=cloud_client,
        )

    assert result.provider == "mock-risk-advisor-v1:fallback"
    assert result.target == "none"
    assert result.candidate_pattern == "off"


def test_combined_risks_use_target_union_and_forefoot_pattern(
    client: TestClient,
) -> None:
    payload = advice_payload(
        risk_type="right_load_bias",
        risk_side="right",
        risk_level=3,
        duration_ms=25_000,
    )
    payload["active_risks"] = [
        payload["risk"],
        {
            "risk_type": "forefoot_high",
            "risk_side": "left",
            "risk_level": 3,
            "duration_ms": 25_000,
        },
    ]

    response = client.post("/api/v1/ai/advice", json=payload)

    assert response.status_code == 200
    assert response.json()["target"] == "both"
    assert response.json()["candidate_pattern"] == "long"


def test_cloud_text_cannot_override_local_motor_safety(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FOOTGUARD_AI_PROVIDER", "openai_compatible")
    monkeypatch.setenv("FOOTGUARD_AI_API_KEY", "test-secret")
    monkeypatch.setenv("FOOTGUARD_AI_MODEL", "competition-model")
    payload = advice_payload(
        risk_type="normal",
        risk_side="none",
        risk_level=0,
        duration_ms=0,
    )

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": (
                                '{"explanation":"当前状态正常。",'
                                '"advice":"立即震动左脚。"}'
                            )
                        }
                    }
                ]
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as cloud_client:
        result = generate_advice(
            AiAdviceRequest.model_validate(payload),
            client=cloud_client,
        )

    assert result.target == "none"
    assert result.candidate_pattern == "off"


def test_configured_cloud_provider_answers_only_selected_question(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FOOTGUARD_AI_PROVIDER", "openai_compatible")
    monkeypatch.setenv("FOOTGUARD_AI_BASE_URL", "https://model.example/v1")
    monkeypatch.setenv("FOOTGUARD_AI_API_KEY", "test-secret")
    monkeypatch.setenv("FOOTGUARD_AI_MODEL", "competition-model")
    payload = advice_payload(
        risk_type="forefoot_high",
        risk_side="right",
        risk_level=2,
    )
    payload["question_key"] = "immediate_action"

    def handler(request: httpx.Request) -> httpx.Response:
        request_body = __import__("json").loads(request.content)
        prompt = request_body["messages"][1]["content"]
        assert "现在应该怎么做？" in prompt
        assert "question_key" not in prompt
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": '{"answer":"请先减轻前掌负荷并观察。"}'
                        }
                    }
                ]
            },
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as cloud_client:
        result = generate_question_answer(
            AiQuestionRequest.model_validate(payload),
            client=cloud_client,
        )

    assert result.provider == "openai-compatible:competition-model"
    assert result.question == "现在应该怎么做？"
    assert result.answer.startswith("请先减轻前掌负荷")
    assert "不能替代医疗诊断" in result.answer
