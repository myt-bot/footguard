from __future__ import annotations

from ..config import MOTOR_COMMAND_LEVEL, MOTOR_PATTERN
from ..schemas import AiAdviceRequest, AiAdviceResponse


MOCK_PROVIDER = "mock-risk-advisor-v1"
MEDICAL_BOUNDARY = "本建议仅用于原型辅助提示，不能替代医疗诊断。"
SUPPORTED_PATTERNS = {"off", "short", "double", "long"}


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
