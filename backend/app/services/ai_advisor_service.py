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
    SessionAdviceResponse,
    SessionQuestionRequest,
    SessionQuestionResponse,
    SessionSummary,
)
from ..schemas import StrictModel


MOCK_PROVIDER = "mock-risk-advisor-v1"
FALLBACK_PROVIDER = "mock-risk-advisor-v1:fallback"
MEDICAL_BOUNDARY = "本建议仅用于辅助监测，不能替代医疗诊断。"
SUPPORTED_PATTERNS = {"off", "short", "double", "long"}
QUESTIONS = {
    "risk_reason": "为什么会出现当前风险？",
    "immediate_action": "现在应该怎么做？",
    "improvement_check": "怎样判断已经改善？",
    "when_to_seek_help": "什么情况需要进一步检查？",
}
SESSION_QUESTIONS = {
    "session_priority": "最近会话最值得优先关注什么？",
    "session_pressure_area": "哪一侧或哪个区域的反复受压最值得复查？",
    "session_improvement": "提醒后的改善是否稳定，哪些指标没有改善？",
    "session_next_test": "下一轮行走测试怎样安排才能减少误报并验证趋势？",
    "session_data_quality": "这次数据里有没有会影响判断的设备或传感器问题？",
}
AUDIENCE_FORBIDDEN_TERMS = (
    "confirmed_issues",
    "risk_counts",
    "motion_state",
    "工程",
    "阈值",
    "三段一致",
    "有效通道",
    "压力帧",
    "传感器编号",
    "事件编号",
    "步时变异",
    "负荷不对称",
    "改善率",
    "马达动作",
    "数据结构",
)
logger = logging.getLogger(__name__)


class CloudAdviceError(RuntimeError):
    pass


class _CloudNarrative(StrictModel):
    explanation: str = Field(min_length=1, max_length=500)
    advice: str = Field(min_length=1, max_length=430)


class _CloudQuestionAnswer(StrictModel):
    answer: str = Field(min_length=1, max_length=430)


class _CloudSessionAdvice(StrictModel):
    advice: str = Field(min_length=1, max_length=650)


def _audience_text(text: str) -> str:
    """Keep cloud output suitable for a public demonstration."""
    value = text.strip()
    if not value or any(term in value for term in AUDIENCE_FORBIDDEN_TERMS):
        raise CloudAdviceError("cloud response contains internal presentation terms")
    return value


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
        gait_text = ""
        if payload.gait and payload.gait.last_completed_episode:
            episode = payload.gait.last_completed_episode
            gait_text = (
                f"最近一次有效行走记录 {episode.step_count} 次落脚，"
                f"估算步频 {episode.cadence_spm:.0f} 步/分钟。"
            )
            primary_issues = [
                item
                for item in episode.issues
                if item.issue_type
                in {"walking_load_asymmetry", "walking_forefoot_concentration"}
            ]
            if primary_issues:
                gait_text += "本段达到行走工程提醒条件，应先停下检查足部和鞋垫。"
            elif payload.gait.confirmed_issues:
                gait_text += "连续三段已形成一致的行走压力趋势。"
            else:
                gait_text += (
                    f"当前已收集 {payload.gait.evidence_episode_count}/3 段证据，"
                    "本段未达到单侧偏载或前掌反复受压提醒条件。"
                )
        text = f"当前压力规则未发现持续异常。{temperature}{gait_text}请继续观察趋势和足部皮肤状态。"
    else:
        text = f"{_explanation(payload)}{_advice(payload)}"
    return text if MEDICAL_BOUNDARY in text else f"{text}{MEDICAL_BOUNDARY}"


def _cloud_chat_prompt(payload: AiChatRequest) -> list[dict[str, str]]:
    return [
        {
            "role": "system",
            "content": (
                "你是足安智垫辅助监测状态助手。只依据结构化状态回答用户问题，"
                "明确区分当前状态与最近一次完整行走；步频偏低本身不等于异常。"
                "单段 issues 中的单侧偏载或前掌反复受压可作为实时工程提醒；"
                "只有 confirmed_issues 才能描述为三段一致的重复趋势。"
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


def _session_fallback(summary: SessionSummary) -> str:
    context = _audience_session_context(summary)
    if summary.session_status == "empty":
        return (
            "最近情况：还没有足够的监测记录可以分析。\n"
            "建议：完成一次自然站立和行走观察后，再查看这里的结果。"
            f"{MEDICAL_BOUNDARY}"
        )
    finding = context["finding"]
    evidence = context["evidence"]
    action = context["action"]
    return (
        f"最近情况：{finding}\n"
        f"依据：{evidence}\n"
        f"建议：{action}"
        f"{MEDICAL_BOUNDARY}"
    )


def _audience_session_context(summary: SessionSummary) -> dict[str, object]:
    """Reduce the engineering summary to language suitable for a live audience."""
    labels = {
        "left_load_bias": "左脚受力偏高",
        "right_load_bias": "右脚受力偏高",
        "forefoot_high": "前掌受力集中",
        "medial_load_concentration": "足内侧受力集中",
        "lateral_load_concentration": "足外侧受力集中",
    }
    gait_labels = {
        "walking_load_asymmetry": "行走时一侧受力偏高",
        "walking_forefoot_concentration": "行走时前掌反复受力",
    }
    rating = summary.monitoring_rating
    rating_text = (
        f"近期监测为“{rating.label}”，{rating.trend_label}"
        if rating is not None
        else "近期监测等级暂不可用"
    )
    findings: list[str] = []
    if summary.gait_trend.confirmed_issues:
        findings.extend(
            gait_labels.get(item.issue_type, "行走受力出现重复变化")
            for item in summary.gait_trend.confirmed_issues[:2]
        )
    if not findings and summary.risk_counts:
        for risk_type, count in sorted(
            summary.risk_counts.items(), key=lambda item: (-item[1], item[0])
        )[:2]:
            if risk_type in labels:
                findings.append(f"{labels[risk_type]}（{count}次提醒）")
    if not findings:
        findings.append("最近没有发现持续的单侧或局部受力异常")

    evidence_parts = [rating_text, "；".join(findings)]
    if summary.gait_trend.evidence_step_count:
        evidence_parts.append(
            f"最近行走记录包含约{summary.gait_trend.evidence_step_count}次落脚"
        )
    for item in summary.improvement_summary[:2]:
        label = labels.get(item.risk_type)
        if not label:
            continue
        if item.median_improvement_ratio is None:
            evidence_parts.append(f"{label}暂时缺少前后对比")
        else:
            percent = round(abs(item.median_improvement_ratio) * 100)
            direction = "有所缓解" if item.median_improvement_ratio >= 0 else "比之前更明显"
            evidence_parts.append(f"{label}{direction}约{percent}%")
    temperature = summary.temperature_evidence
    demo_records = [record for record in temperature.records if record.source == "demo"]
    if demo_records:
        demo = demo_records[0]
        demo_side = "右脚" if demo.side == "right" else "左脚"
        demo_state = "已预置" if demo.quality == "prepared_demo" else "记录为"
        evidence_parts.append(
            f"现场演示{demo_state}{demo_side}{demo.zone}一次温度变化，属于演示数据，不代表真实两日临床证据"
        )
    elif temperature.real_consecutive_days >= 2:
        evidence_parts.append("温度观察在连续两天都出现同一区域变化")
    elif temperature.real_days:
        evidence_parts.append("真实温度观察目前记录了一个自然日；现场演示不等同于真实两日证据")
    if summary.recent_glucose_readings:
        evidence_parts.append("同时记录了手动血糖，作为背景参考")
    health_labels = {"no": "无", "yes": "有", "unknown": "不确定"}
    profile = summary.health_profile
    evidence_parts.append(
        "足部背景：既往足部溃疡或截肢"
        f"{health_labels.get(profile.ulcer_or_amputation, '不确定')}；"
        "医生提示感觉减退或供血问题"
        f"{health_labels.get(profile.sensory_or_circulation_issue, '不确定')}"
    )
    if not summary.baseline_ready or not summary.pressure_available:
        evidence_parts.append("本次压力资料还不完整")
    elif summary.pressure_untrusted_channels:
        evidence_parts.append("部分压力资料质量不足，结论需要谨慎看待")

    action = (
        "先检查受力较高一侧的鞋内异物、鞋垫贴合和皮肤外观；"
        "下一次在平直路面自然走几步并观察是否重复。若同一部位持续出现异常，"
        "或皮肤出现红肿、破损、明显发热，请停止负重并请专业人员评估。"
    )
    return {
        "time_scope": "当前会话" if summary.session_status == "live" else "最近一次完整会话",
        "finding": "；".join(findings) + "。",
        "evidence": "；".join(evidence_parts) + "。",
        "action": action,
    }


def _cloud_session_prompt(summary: SessionSummary) -> list[dict[str, str]]:
    return [
        {
            "role": "system",
            "content": (
                "你是足安智垫的现场讲解助手。只依据提供的观众版摘要，写一段简洁、自然的中文，"
                "让没有医学或软件背景的人能听懂。只说最近最重要的一两个发现、它们的依据和下一步建议；"
                "不要逐条复述记录，不要展示字段名、内部规则、计算阈值、传感器编号、通道数量、马达动作、"
                "步态算法名称或数据结构。可以说有几次提醒、是否反复出现和是否有所缓解，但不要使用“工程指标”、"
                "“三段一致”“有效通道”等开发术语。明确区分真实温度观察和一次现场演示；"
                "足部背景只用于调整建议的谨慎程度，不改变设备评级；血糖只作为背景。"
                "不得诊断疾病、预测溃疡或把演示当成真实临床证据。输出 JSON 且只包含 advice 字符串，"
                f"末尾必须说明：{MEDICAL_BOUNDARY}"
            ),
        },
        {
            "role": "user",
            "content": json.dumps(
                _audience_session_context(summary),
                ensure_ascii=False,
                separators=(",", ":"),
            ),
        },
    ]


def _session_question_fallback(
    summary: SessionSummary, request: SessionQuestionRequest
) -> str:
    pressure_labels = {
        "left_load_bias": "左侧负载持续偏高",
        "right_load_bias": "右侧负载持续偏高",
        "forefoot_high": "前掌负荷持续集中",
        "medial_load_concentration": "内侧局部负荷集中",
        "lateral_load_concentration": "外侧局部负荷集中",
    }
    key = request.question_key
    if summary.session_status == "empty":
        answer = "目前还没有足够的最近记录。先完成一次自然站立和行走观察，再回来比较。"
    elif key == "session_priority":
        if summary.gait_trend.confirmed_issues:
            labels = {
                "walking_load_asymmetry": "持续单侧行走偏载",
                "walking_forefoot_concentration": "前掌反复受压",
            }
            answer = "最近多次行走都出现" + "、".join(
                labels.get(item.issue_type, item.issue_type)
                for item in summary.gait_trend.confirmed_issues
            ) + "，建议检查对应区域皮肤和鞋垫贴合。"
        else:
            pressure = [
                item for item in summary.risk_counts.items() if item[0] in pressure_labels
            ]
            if pressure:
                name, count = max(pressure, key=lambda item: item[1])
                answer = f"优先复查{pressure_labels[name]}，最近出现过 {count} 次提醒；下一次自然行走时观察是否仍在同一侧。"
            else:
                answer = "最近没有形成需要优先处理的持续受力或重复行走变化，继续观察皮肤和行走感受即可。"
    elif key == "session_pressure_area":
        pressure = sorted(
            (
                (name, count)
                for name, count in summary.risk_counts.items()
                if name in pressure_labels
            ),
            key=lambda item: (-item[1], item[0]),
        )
        answer = (
            f"最值得复查的是{pressure_labels[pressure[0][0]]}，最近出现过 {pressure[0][1]} 次提醒。"
            if pressure
            else "最近没有明确的反复受力区域；下一次走动时留意是否仍在同一侧或同一区域出现不适。"
        )
    elif key == "session_improvement":
        parts = []
        for item in summary.improvement_summary:
            label = pressure_labels.get(item.risk_type, item.risk_type)
            if item.median_improvement_ratio is None:
                parts.append(f"{label}暂时无法比较")
            elif item.median_improvement_ratio < 0:
                parts.append(f"{label}偏离增加 {round(-item.median_improvement_ratio * 100)}%")
            else:
                parts.append(f"{label}中位改善 {round(item.median_improvement_ratio * 100)}%")
        answer = (
            "；".join(parts[:3]) + "。这里的改善只表示本次监测前后变化，不能替代专业评估。"
            if parts
            else "最近没有足够的前后记录，暂时不能判断提醒后是否稳定改善。"
        )
    elif key == "session_next_test":
        answer = (
            "先自然站立片刻，再在平直路面连续走十几步；转弯或停下后再重新开始，"
            "重复几次相同路线，观察是否总在同一侧或同一区域出现提醒。"
        )
    else:
        if summary.pressure_untrusted_channels or not summary.pressure_available:
            answer = "本次部分压力资料不完整，结论需要谨慎看待；重新穿戴并确认鞋垫贴合后再测一次。"
        elif not summary.temperature_available or summary.temperature_valid_pairs < 2:
            answer = "压力资料可以参考，但温度资料不完整；温度相关判断请在设备连接稳定后再复测。"
        else:
            answer = "目前没有发现会明显影响理解的设备问题，可以按最近的受力和温度变化继续观察。"
    return answer if MEDICAL_BOUNDARY in answer else f"{answer}{MEDICAL_BOUNDARY}"


def _cloud_session_question_prompt(
    summary: SessionSummary, request: SessionQuestionRequest
) -> list[dict[str, str]]:
    return [
        {
            "role": "system",
            "content": (
                "你是足安智垫的现场讲解助手，只回答给出的一个问题。只依据观众版摘要，"
                "用简洁自然的中文回答，让没有医学或软件背景的人能听懂。不要输出字段名、阈值、"
                "传感器编号、通道数量、马达动作、算法名称或数据结构，不要逐条复述记录。"
                "明确区分真实温度观察和一次现场演示；足部背景只用于建议上下文，血糖只作为背景。"
                "不得诊断、预测溃疡或把演示当成真实临床证据。"
                "输出 JSON，且只包含 answer 字符串。"
                f"末尾必须说明：{MEDICAL_BOUNDARY}"
            ),
        },
        {
            "role": "user",
            "content": json.dumps(
                {
                    "question": SESSION_QUESTIONS[request.question_key],
                    "session_summary": _audience_session_context(summary),
                },
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
        if risk.risk_type in {
            "forefoot_high",
            "medial_load_concentration",
            "lateral_load_concentration",
            "temperature_asymmetry",
        }:
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
    if any(
        risk.risk_type
        in {
            "forefoot_high",
            "medial_load_concentration",
            "lateral_load_concentration",
        }
        for risk in risks
    ):
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
    if risk.risk_type in {
        "medial_load_concentration",
        "lateral_load_concentration",
    }:
        region = "内侧" if risk.risk_type.startswith("medial") else "外侧"
        side = "左脚" if risk.risk_side == "left" else "右脚"
        return f"检测到{side}{region}局部负荷持续集中，当前风险等级为 {risk.risk_level}。"
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
    if risk_type in {
        "medial_load_concentration",
        "lateral_load_concentration",
    }:
        return (
            "请短暂休息并减轻对应区域受力，检查袜鞋、鞋垫贴合和皮肤状态，随后观察局部负荷是否回落。"
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


def _request_cloud_session_advice(
    summary: SessionSummary,
    settings: _CloudSettings,
    client: httpx.Client | None = None,
) -> _CloudSessionAdvice:
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
                "messages": _cloud_session_prompt(summary),
                "temperature": 0.2,
            },
        )
        response.raise_for_status()
        content = response.json()["choices"][0]["message"]["content"]
        if not isinstance(content, str):
            raise CloudAdviceError("cloud response content is not text")
        return _CloudSessionAdvice.model_validate_json(content)
    except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as error:
        raise CloudAdviceError("cloud provider returned an invalid response") from error
    finally:
        if owns_client:
            active_client.close()


def _request_cloud_session_question(
    summary: SessionSummary,
    request: SessionQuestionRequest,
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
                "messages": _cloud_session_question_prompt(summary, request),
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


def generate_session_advice(
    summary: SessionSummary,
    client: httpx.Client | None = None,
) -> SessionAdviceResponse:
    settings = _cloud_settings()
    if settings is None:
        return SessionAdviceResponse(
            provider=f"{MOCK_PROVIDER}:session",
            session_status=summary.session_status,
            advice=_session_fallback(summary),
        )
    try:
        narrative = _request_cloud_session_advice(summary, settings, client)
        advice = _audience_text(narrative.advice)
        if MEDICAL_BOUNDARY not in advice:
            advice = f"{advice}{MEDICAL_BOUNDARY}"
        return SessionAdviceResponse(
            provider=_cloud_provider_name(settings.model),
            session_status=summary.session_status,
            advice=advice,
        )
    except CloudAdviceError as error:
        logger.warning("Cloud session advice unavailable; using fallback: %s", error)
        return SessionAdviceResponse(
            provider=f"{FALLBACK_PROVIDER}:session",
            session_status=summary.session_status,
            advice=_session_fallback(summary),
        )


def generate_session_question_answer(
    summary: SessionSummary,
    request: SessionQuestionRequest,
    client: httpx.Client | None = None,
) -> SessionQuestionResponse:
    settings = _cloud_settings()
    if settings is None:
        return SessionQuestionResponse(
            provider=f"{MOCK_PROVIDER}:session",
            question_key=request.question_key,
            question=SESSION_QUESTIONS[request.question_key],
            answer=_session_question_fallback(summary, request),
        )
    try:
        narrative = _request_cloud_session_question(
            summary, request, settings, client
        )
        answer = _audience_text(narrative.answer)
        if MEDICAL_BOUNDARY not in answer:
            answer = f"{answer}{MEDICAL_BOUNDARY}"
        return SessionQuestionResponse(
            provider=_cloud_provider_name(settings.model),
            question_key=request.question_key,
            question=SESSION_QUESTIONS[request.question_key],
            answer=answer,
        )
    except CloudAdviceError as error:
        logger.warning("Cloud session question unavailable; using fallback: %s", error)
        return SessionQuestionResponse(
            provider=f"{FALLBACK_PROVIDER}:session",
            question_key=request.question_key,
            question=SESSION_QUESTIONS[request.question_key],
            answer=_session_question_fallback(summary, request),
        )
