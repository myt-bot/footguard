from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import httpx
from pydantic import Field

from ..config import (
    MOTOR_COMMAND_LEVEL,
    MOTOR_PATTERN,
    ai_api_key,
    ai_base_url,
    ai_model,
    ai_provider,
    ai_timeout_seconds,
)
from ..schemas import AiAdviceRequest, AiAdviceResponse
from ..schemas import StrictModel


MOCK_PROVIDER = "mock-risk-advisor-v1"
FALLBACK_PROVIDER = "mock-risk-advisor-v1:fallback"
MEDICAL_BOUNDARY = "本建议仅用于原型辅助提示，不能替代医疗诊断。"
SUPPORTED_PATTERNS = {"off", "short", "double", "long"}
logger = logging.getLogger(__name__)


class CloudAdviceError(RuntimeError):
    pass


class _CloudNarrative(StrictModel):
    explanation: str = Field(min_length=1, max_length=500)
    advice: str = Field(min_length=1, max_length=430)


@dataclass(frozen=True)
class _CloudSettings:
    base_url: str
    api_key: str
    model: str
    timeout_seconds: float


def _cloud_settings() -> _CloudSettings | None:
    if ai_provider() != "openai_compatible":
        return None
    api_key = ai_api_key()
    model = ai_model()
    if not api_key or not model:
        return None
    return _CloudSettings(
        base_url=ai_base_url(),
        api_key=api_key,
        model=model,
        timeout_seconds=ai_timeout_seconds(),
    )


def _risk_target(payload: AiAdviceRequest) -> str:
    risk = payload.risk
    if risk.risk_type == "left_load_bias":
        return "left" if risk.risk_side == "left" else "none"
    if risk.risk_type == "right_load_bias":
        return "right" if risk.risk_side == "right" else "none"
    if risk.risk_type in {"forefoot_high", "temperature_asymmetry"}:
        return risk.risk_side if risk.risk_side in {"left", "right", "both"} else "none"
    return "none"


def _candidate_pattern(payload: AiAdviceRequest, target: str) -> str:
    if target == "none" or payload.risk.risk_level < MOTOR_COMMAND_LEVEL:
        return "off"
    if MOTOR_PATTERN not in SUPPORTED_PATTERNS:
        raise RuntimeError(f"unsupported MOTOR_PATTERN: {MOTOR_PATTERN}")
    return MOTOR_PATTERN


def _explanation(payload: AiAdviceRequest) -> str:
    risk = payload.risk
    if risk.risk_type == "normal":
        return "当前双足压力与温度对比未发现达到规则阈值的明显异常。"
    if risk.risk_type == "data_incomplete":
        return "当前双足数据不完整，无法形成可靠的风险解释。"
    if risk.risk_type == "left_load_bias":
        detail = (
            f"，当前左右负荷差为 {payload.load_diff:.3f}"
            if payload.load_diff is not None
            else ""
        )
        return f"检测到左脚承重相对偏高并达到风险等级 {risk.risk_level}{detail}。"
    if risk.risk_type == "right_load_bias":
        detail = (
            f"，当前左右负荷差为 {payload.load_diff:.3f}"
            if payload.load_diff is not None
            else ""
        )
        return f"检测到右脚承重相对偏高并达到风险等级 {risk.risk_level}{detail}。"
    if risk.risk_type == "forefoot_high":
        return f"检测到前掌区域相对压力持续偏高，当前风险等级为 {risk.risk_level}。"
    if risk.risk_type == "temperature_asymmetry":
        detail = (
            f"，最大同区温差约 {payload.temperature_delta_max_c:.1f}℃"
            if payload.temperature_delta_max_c is not None
            else ""
        )
        return f"检测到双足同区域温度不对称，当前风险等级为 {risk.risk_level}{detail}。"
    raise ValueError(f"unsupported risk type: {risk.risk_type}")


def _advice(payload: AiAdviceRequest) -> str:
    risk_type = payload.risk.risk_type
    if risk_type == "normal":
        return "继续保持当前状态并观察趋势；如有不适，请及时检查足部。"
    if risk_type == "data_incomplete":
        return "请检查左右脚设备连接、传感器接触和供电，数据恢复后再判断风险。"
    if risk_type in {"left_load_bias", "right_load_bias"}:
        return (
            "请适当调整站姿或短暂休息，检查鞋内是否有异物，并观察负荷是否恢复均衡。"
            f"{MEDICAL_BOUNDARY}"
        )
    if risk_type == "forefoot_high":
        return (
            "请减轻前掌持续受力，短暂休息并检查鞋垫与鞋内异物，随后观察压力是否回落。"
            f"{MEDICAL_BOUNDARY}"
        )
    if risk_type == "temperature_asymmetry":
        return (
            "请检查对应足部皮肤、袜鞋和局部受压情况；若温差持续或伴随红肿破损，"
            f"建议寻求专业评估。{MEDICAL_BOUNDARY}"
        )
    raise ValueError(f"unsupported risk type: {risk_type}")


def generate_mock_advice(payload: AiAdviceRequest) -> AiAdviceResponse:
    """Return deterministic advice while the real cloud provider is not configured."""
    target = _risk_target(payload)
    return AiAdviceResponse(
        provider=MOCK_PROVIDER,
        risk_level=payload.risk.risk_level,
        explanation=_explanation(payload),
        advice=_advice(payload),
        target=target,
        candidate_pattern=_candidate_pattern(payload, target),
    )


def _cloud_prompt(payload: AiAdviceRequest) -> list[dict[str, str]]:
    system_prompt = (
        "你是糖尿病足辅助监测原型的风险解释助手。"
        "只根据用户提供的结构化数据，用简洁中文输出 JSON 对象，"
        '且只能包含 "explanation" 和 "advice" 两个字符串字段。'
        "不得诊断疾病，不得虚构数值，不得决定或描述马达控制参数。"
        "explanation 说明规则引擎已经识别出的现象；"
        "advice 给出低风险、可执行的观察或检查建议。"
    )
    user_payload = json.dumps(
        payload.model_dump(mode="json"),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_payload},
    ]


def _request_cloud_narrative(
    payload: AiAdviceRequest,
    settings: _CloudSettings,
    client: httpx.Client | None = None,
) -> _CloudNarrative:
    owns_client = client is None
    active_client = client or httpx.Client(timeout=settings.timeout_seconds)
    try:
        response = active_client.post(
            f"{settings.base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {settings.api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": settings.model,
                "messages": _cloud_prompt(payload),
                "temperature": 0.2,
            },
        )
        response.raise_for_status()
        body = response.json()
        content = body["choices"][0]["message"]["content"]
        if not isinstance(content, str):
            raise CloudAdviceError("cloud response content is not text")
        return _CloudNarrative.model_validate_json(content)
    except (
        httpx.HTTPError,
        KeyError,
        IndexError,
        TypeError,
        ValueError,
    ) as error:
        raise CloudAdviceError("cloud provider returned an invalid response") from error
    finally:
        if owns_client:
            active_client.close()


def _cloud_provider_name(model: str) -> str:
    return f"openai-compatible:{model}"[:64]


def _safe_cloud_advice(
    payload: AiAdviceRequest,
    settings: _CloudSettings,
    client: httpx.Client | None = None,
) -> AiAdviceResponse:
    narrative = _request_cloud_narrative(payload, settings, client)
    target = _risk_target(payload)
    advice = narrative.advice
    if payload.risk.risk_type not in {"normal", "data_incomplete"}:
        advice = f"{advice.rstrip()}{MEDICAL_BOUNDARY}"
    return AiAdviceResponse(
        provider=_cloud_provider_name(settings.model),
        risk_level=payload.risk.risk_level,
        explanation=narrative.explanation,
        advice=advice,
        target=target,
        candidate_pattern=_candidate_pattern(payload, target),
    )


def generate_advice(
    payload: AiAdviceRequest,
    client: httpx.Client | None = None,
) -> AiAdviceResponse:
    """Use a configured cloud model, with a deterministic fail-safe fallback."""
    settings = _cloud_settings()
    if settings is None:
        return generate_mock_advice(payload)
    try:
        return _safe_cloud_advice(payload, settings, client)
    except CloudAdviceError as error:
        logger.warning("Cloud AI unavailable; falling back to mock advice: %s", error)
        fallback = generate_mock_advice(payload)
        return fallback.model_copy(update={"provider": FALLBACK_PROVIDER})
