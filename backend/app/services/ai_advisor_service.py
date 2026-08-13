from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import httpx
from pydantic import Field

from ..config import (
    MOTOR_COMMAND_LEVEL,
    ai_api_key,
    ai_base_url,
    ai_model,
    ai_provider,
    ai_timeout_seconds,
)
from ..schemas import (
    AiAdviceRequest,
    AiAdviceResponse,
    AiChatRequest,
    AiChatResponse,
    AiQuestionRequest,
    AiQuestionResponse,
)
from ..schemas import StrictModel


MOCK_PROVIDER = "mock-risk-advisor-v1"
FALLBACK_PROVIDER = "mock-risk-advisor-v1:fallback"
MEDICAL_BOUNDARY = "本建议仅用于原型辅助提示，不能替代医疗诊断。"
SUPPORTED_PATTERNS = {"off", "short", "double", "long"}
QUESTIONS = {
    "risk_reason": "为什么会出现当前风险？",
    "immediate_action": "现在应该怎么做？",
    "improvement_check": "怎样判断已经改善？",
    "when_to_seek_help": "什么情况需要进一步检查？",
}
logger = logging.getLogger(__name__)


class CloudAdviceError(RuntimeError):
    pass


class _CloudNarrative(StrictModel):
    explanation: str = Field(min_length=1, max_length=500)
    advice: str = Field(min_length=1, max_length=430)


class _CloudQuestionAnswer(StrictModel):
    answer: str = Field(min_length=1, max_length=430)


def _chat_fallback(payload: AiChatRequest) -> str:
    if not payload.left_connected or not payload.right_connected:
        text = "当前左右设备连接不完整，请先恢复双脚连接和同步，再解读双足风险。"
    elif not payload.pressure_available:
        text = "当前压力数据不可用，请检查压力通道、鞋垫接触和连接状态。"
    elif not payload.baseline_ready:
        text = "当前正在建立本次穿戴基线，请双脚平行自然站立约 8–12 秒。"
    elif payload.risk.risk_type == "normal":
        temperature = (
            "温度数据当前不可用，但不影响压力监测。"
            if not payload.temperature_available
            else "有效温度点暂未达到风险阈值。"
        )
        text = f"当前压力规则未发现持续异常。{temperature}请继续观察趋势和足部皮肤状态。"
    else:
        text = f"{_explanation(payload)}{_advice(payload)}"
    return text if MEDICAL_BOUNDARY in text else f"{text}{MEDICAL_BOUNDARY}"


def _cloud_chat_prompt(payload: AiChatRequest) -> list[dict[str, str]]:
    return [
        {
            "role": "system",
            "content": (
                "你是足安智垫辅助监测状态助手。只依据结构化状态回答用户问题，"
                "不得诊断疾病、虚构数值或决定马达动作。用简洁中文输出 JSON，"
                f"只包含 answer 字符串，末尾说明：{MEDICAL_BOUNDARY}"
            ),
        },
        {
            "role": "user",
            "content": json.dumps(
                payload.model_dump(mode="json"),
                ensure_ascii=False,
                separators=(",", ":"),
            ),
        },
    ]


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
    risks = payload.active_risks or [payload.risk]

    def valid_sides(risk: RiskState) -> tuple[str, ...]:
        if risk.risk_type == "left_load_bias":
            return ("left",) if risk.risk_side == "left" else ()
        if risk.risk_type == "right_load_bias":
            return ("right",) if risk.risk_side == "right" else ()
        if risk.risk_type in {"forefoot_high", "temperature_asymmetry"}:
            if risk.risk_side == "both":
                return ("left", "right")
            return (risk.risk_side,) if risk.risk_side in {"left", "right"} else ()
        return ()

    sides = {
        side
        for risk in risks
        if risk.risk_level >= MOTOR_COMMAND_LEVEL
        for side in valid_sides(risk)
    }
    if sides == {"left", "right"}:
        return "both"
    return next(iter(sides)) if sides else "none"


def _candidate_pattern(payload: AiAdviceRequest, target: str) -> str:
    risks = [
        risk
        for risk in (payload.active_risks or [payload.risk])
        if risk.risk_level >= MOTOR_COMMAND_LEVEL
    ]
    if target == "none" or not risks:
        return "off"
    if any(risk.risk_type == "forefoot_high" for risk in risks):
        pattern = "long"
    elif any(risk.risk_type in {"left_load_bias", "right_load_bias"} for risk in risks):
        pattern = "double"
    elif any(risk.risk_type == "temperature_asymmetry" for risk in risks):
        pattern = "short"
    else:
        pattern = "off"
    if pattern not in SUPPORTED_PATTERNS:
        raise RuntimeError(f"unsupported motor pattern: {pattern}")
    return pattern


def _explanation(payload: AiAdviceRequest) -> str:
    risk = payload.risk
    if risk.risk_type == "normal":
        if not payload.left_connected or not payload.right_connected:
            return "当前左右设备连接不完整，暂时不能形成可靠的双足风险结论。"
        if not payload.pressure_available:
            return "当前压力有效点不足，压力风险判断已暂停。"
        if not payload.baseline_ready:
            return "当前正在建立本次穿戴压力基线，热力图可见但压力风险尚未启用。"
        if not payload.temperature_available:
            return "当前压力规则未发现持续异常；温度数据不可用，但不会影响压力监测。"
        return "当前双足压力与有效温度对比未发现达到规则阈值的明显异常。"
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
        if not payload.left_connected or not payload.right_connected:
            return "请先恢复左右设备连接和同步，再解读双足状态。"
        if not payload.pressure_available:
            return "请检查压力通道、鞋垫接触和接线，恢复足够有效点后再判断压力风险。"
        if not payload.baseline_ready:
            return "请双脚平行自然站立约 8–12 秒，等待本次穿戴基线完成。"
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


def _mock_question_answer(payload: AiQuestionRequest) -> str:
    if payload.question_key == "risk_reason":
        return _explanation(payload)
    if payload.question_key == "immediate_action":
        return _advice(payload)
    if payload.question_key == "improvement_check":
        if payload.risk.risk_type == "temperature_asymmetry":
            return (
                "继续观察左右脚同一区域温差是否稳定回落，同时检查局部皮肤、袜鞋和受压情况。"
                f"{MEDICAL_BOUNDARY}"
            )
        if payload.risk.risk_type == "data_incomplete":
            return "先恢复双足有效数据；数据不完整时不能可靠判断是否改善。"
        return (
            "观察异常区域压力是否回到个人基线附近、左右负载差是否下降，"
            f"并确认风险等级能够持续回落。{MEDICAL_BOUNDARY}"
        )
    if payload.question_key == "when_to_seek_help":
        return (
            "若出现持续红肿发热、破损、水疱、渗液、颜色改变，或异常在休息和调整后仍持续，"
            "建议尽快请专业人员评估；糖尿病患者即使疼痛不明显也不应忽视皮肤变化。"
            f"{MEDICAL_BOUNDARY}"
        )
    raise ValueError(f"unsupported question key: {payload.question_key}")


def generate_mock_question_answer(
    payload: AiQuestionRequest,
    *,
    provider: str = MOCK_PROVIDER,
) -> AiQuestionResponse:
    answer = _mock_question_answer(payload).rstrip()
    if MEDICAL_BOUNDARY not in answer:
        answer = f"{answer}{MEDICAL_BOUNDARY}"
    return AiQuestionResponse(
        provider=provider,
        question_key=payload.question_key,
        question=QUESTIONS[payload.question_key],
        answer=answer,
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


def _cloud_question_prompt(payload: AiQuestionRequest) -> list[dict[str, str]]:
    system_prompt = (
        "你是糖尿病足辅助监测原型的科普问答助手。"
        "用户只能选择系统预设问题，你只能依据给定结构化数据回答该问题。"
        '用简洁中文输出 JSON 对象，且只能包含 "answer" 一个字符串字段。'
        "不得诊断疾病，不得虚构数值，不得决定马达行为；"
        f"回答末尾必须说明：{MEDICAL_BOUNDARY}"
    )
    user_payload = json.dumps(
        {
            "question": QUESTIONS[payload.question_key],
            "monitoring_context": payload.model_dump(
                mode="json",
                exclude={"question_key"},
            ),
        },
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


def _request_cloud_question_answer(
    payload: AiQuestionRequest,
    settings: _CloudSettings,
    client: httpx.Client | None = None,
) -> _CloudQuestionAnswer:
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
                "messages": _cloud_question_prompt(payload),
                "temperature": 0.2,
            },
        )
        response.raise_for_status()
        body = response.json()
        content = body["choices"][0]["message"]["content"]
        if not isinstance(content, str):
            raise CloudAdviceError("cloud response content is not text")
        return _CloudQuestionAnswer.model_validate_json(content)
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


def _request_cloud_chat_answer(
    payload: AiChatRequest,
    settings: _CloudSettings,
    client: httpx.Client | None = None,
) -> _CloudQuestionAnswer:
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
                "messages": _cloud_chat_prompt(payload),
                "temperature": 0.2,
            },
        )
        response.raise_for_status()
        content = response.json()["choices"][0]["message"]["content"]
        if not isinstance(content, str):
            raise CloudAdviceError("cloud response content is not text")
        return _CloudQuestionAnswer.model_validate_json(content)
    except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as error:
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


def generate_question_answer(
    payload: AiQuestionRequest,
    client: httpx.Client | None = None,
) -> AiQuestionResponse:
    """Answer one allow-listed question, with a deterministic safe fallback."""
    settings = _cloud_settings()
    if settings is None:
        return generate_mock_question_answer(payload)
    try:
        narrative = _request_cloud_question_answer(payload, settings, client)
        answer = narrative.answer.rstrip()
        if MEDICAL_BOUNDARY not in answer:
            answer = f"{answer}{MEDICAL_BOUNDARY}"
        return AiQuestionResponse(
            provider=_cloud_provider_name(settings.model),
            question_key=payload.question_key,
            question=QUESTIONS[payload.question_key],
            answer=answer,
        )
    except CloudAdviceError as error:
        logger.warning(
            "Cloud AI question unavailable; falling back to mock answer: %s",
            error,
        )
        return generate_mock_question_answer(
            payload,
            provider=FALLBACK_PROVIDER,
        )


def generate_chat_answer(
    payload: AiChatRequest,
    client: httpx.Client | None = None,
) -> AiChatResponse:
    settings = _cloud_settings()
    if settings is None:
        return AiChatResponse(
            provider=MOCK_PROVIDER,
            question=payload.question,
            answer=_chat_fallback(payload),
        )
    try:
        narrative = _request_cloud_chat_answer(payload, settings, client)
        answer = narrative.answer.rstrip()
        if MEDICAL_BOUNDARY not in answer:
            answer = f"{answer}{MEDICAL_BOUNDARY}"
        return AiChatResponse(
            provider=_cloud_provider_name(settings.model),
            question=payload.question,
            answer=answer,
        )
    except CloudAdviceError as error:
        logger.warning("Cloud AI chat unavailable; using fallback: %s", error)
        return AiChatResponse(
            provider=FALLBACK_PROVIDER,
            question=payload.question,
            answer=_chat_fallback(payload),
        )
