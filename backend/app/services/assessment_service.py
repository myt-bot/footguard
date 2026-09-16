from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ..models import (
    CalibrationState,
    GaitEpisode,
    GlucoseReading as GlucoseReadingModel,
    HealthProfile as HealthProfileModel,
    MonitoringSession,
    RiskEvent,
    SensorFrame,
    TemperatureDailyRecord,
    TemperatureDemoState,
)
from ..schemas import (
    AssessmentSummary,
    GlucoseReading,
    HealthProfile,
    MonitoringRatingSummary,
    TemperatureDailyRecordOut,
    TemperatureEvidenceSummary,
)

STATE_KEY = "active"
HEALTH_PROFILE_KEY = "default"
DEMO_STATE_KEY = "active"


def _date_for(timestamp_ms: int) -> str:
    return datetime.fromtimestamp(timestamp_ms / 1000, tz=timezone.utc).date().isoformat()


def _rating(level: int, evidence: list[str], quality: list[str], *, session_id: str | None, demo_only: bool = False) -> MonitoringRatingSummary:
    values = {
        0: ("normal", "正常"),
        1: ("attention", "关注"),
        2: ("review", "需复核"),
        3: ("persistent", "持续异常"),
    }
    rating, label = values.get(level, ("insufficient_data", "数据不足"))
    if not quality and level == 0:
        quality = ["有效压力、步态和温度数据达到最低观察条件"]
    return MonitoringRatingSummary(
        rating=rating,
        level=level,
        label=label,
        trend="unavailable",
        trend_label="暂无可比较的上一次会话",
        evidence=evidence,
        data_quality=quality,
        session_id=session_id,
        is_demo_only=demo_only,
    )


def temperature_records(session: Session, *, include_demo: bool = True, limit: int = 100) -> list[TemperatureDailyRecordOut]:
    query = select(TemperatureDailyRecord).order_by(
        TemperatureDailyRecord.record_date.desc(),
        TemperatureDailyRecord.ended_at_ms.desc(),
    )
    if not include_demo:
        query = query.where(TemperatureDailyRecord.source != "demo")
    rows = list(session.scalars(query.limit(limit)))
    return [TemperatureDailyRecordOut.model_validate(row, from_attributes=True) for row in rows]


def temperature_evidence(
    session: Session, *, after_ms: int | None = None
) -> TemperatureEvidenceSummary:
    query = select(TemperatureDailyRecord).order_by(
        TemperatureDailyRecord.record_date.desc(),
        TemperatureDailyRecord.ended_at_ms.desc(),
    )
    if after_ms is not None:
        query = query.where(TemperatureDailyRecord.ended_at_ms >= after_ms)
    rows = list(session.scalars(query))
    real_dates = sorted({row.record_date for row in rows if row.source != "demo"})
    real_consecutive = 0
    if real_dates:
        real_consecutive = 1
        for older, newer in zip(real_dates, real_dates[1:]):
            if datetime.fromisoformat(newer) - datetime.fromisoformat(older) == timedelta(days=1):
                real_consecutive += 1
            else:
                real_consecutive = 1
    demo_dates = {row.record_date for row in rows if row.source == "demo"}
    if not rows:
        status = "no_data"
    elif real_consecutive >= 2:
        status = "two_day"
    elif real_dates:
        status = "single_day"
    elif demo_dates:
        status = "demo_single"
    else:
        status = "insufficient_data"
    return TemperatureEvidenceSummary(
        real_days=len(real_dates),
        real_consecutive_days=real_consecutive,
        demo_days=len(demo_dates),
        status=status,
        records=[TemperatureDailyRecordOut.model_validate(row, from_attributes=True) for row in rows[:100]],
    )


def health_profile(session: Session) -> HealthProfile:
    row = session.get(HealthProfileModel, HEALTH_PROFILE_KEY)
    if row is None:
        return HealthProfile()
    complete = row.ulcer_or_amputation != "unknown" and row.sensory_or_circulation_issue != "unknown"
    return HealthProfile(
        ulcer_or_amputation=row.ulcer_or_amputation,
        sensory_or_circulation_issue=row.sensory_or_circulation_issue,
        completeness="complete" if complete else "incomplete",
    )


def glucose_readings(session: Session, limit: int = 30) -> list[GlucoseReading]:
    rows = list(
        session.scalars(
            select(GlucoseReadingModel)
            .order_by(GlucoseReadingModel.measured_at_ms.desc())
            .limit(limit)
        )
    )
    return [GlucoseReading.model_validate(row, from_attributes=True) for row in rows]


def _current_session_id(session: Session) -> str | None:
    state = session.get(CalibrationState, "personal_baseline")
    if state is None or state.reset_at_ms is None:
        return None
    return f"session_{state.reset_at_ms}"


def current_rating(session: Session) -> MonitoringRatingSummary:
    state = session.get(CalibrationState, "personal_baseline")
    reset_at = state.reset_at_ms if state and state.reset_at_ms else 0
    event_rows = list(
        session.scalars(
            select(RiskEvent).where(
                RiskEvent.started_at_ms >= reset_at,
                RiskEvent.risk_type != "temperature_asymmetry",
            )
        )
    )
    gait_rows = list(
        session.scalars(
            select(GaitEpisode).where(GaitEpisode.reset_at_ms >= reset_at)
        )
    )
    temp = temperature_evidence(session, after_ms=reset_at if reset_at else None)
    recent_frames = list(
        session.scalars(
            select(SensorFrame)
            .where(SensorFrame.timestamp_ms >= reset_at)
            .order_by(SensorFrame.timestamp_ms.desc())
            .limit(800)
        )
    )
    valid_frames = {
        side: sum(
            1
            for frame in recent_frames
            if frame.side == side and frame.quality_flags & 0x3F == 0
        )
        for side in ("left", "right")
    }
    data_sufficient = all(valid_frames[side] >= 20 for side in ("left", "right"))
    evidence: list[str] = []
    quality: list[str] = []
    if event_rows:
        evidence.append(f"本次会话记录 {len(event_rows)} 条持续压力事件")
    if gait_rows:
        evidence.append(f"本次会话保存 {len(gait_rows)} 段完整行走")
    if temp.real_days:
        evidence.append(f"真实温度观察 {temp.real_days} 个自然日")
    if temp.demo_days:
        quality.append(f"另有 {temp.demo_days} 个演示日期，不计入真实评级")
    if not event_rows and not gait_rows and not temp.real_days:
        quality.append("尚未形成持续事件、完整行走或真实温度日记录")
    if not reset_at:
        result = _rating(0, evidence, ["尚未建立明确的穿戴会话"], session_id=None)
        return result.model_copy(update={"rating": "insufficient_data", "label": "数据不足"})
    if not data_sufficient:
        quality.append(
            f"有效压力帧不足：左 {valid_frames['left']}、右 {valid_frames['right']}，每侧至少需要 20 帧"
        )
        result = _rating(0, evidence, quality, session_id=_current_session_id(session))
        return result.model_copy(update={"rating": "insufficient_data", "label": "数据不足"})
    if not event_rows and not gait_rows and not temp.real_days:
        return _rating(0, evidence, quality, session_id=_current_session_id(session))
    level = 0
    if event_rows or gait_rows or temp.real_days:
        level = 1
    if len(event_rows) >= 2 or any(row.step_count >= 18 for row in gait_rows) or temp.real_consecutive_days >= 2:
        level = 2
    previous = session.scalar(
        select(MonitoringSession)
        .where(MonitoringSession.started_at_ms < reset_at)
        .order_by(MonitoringSession.started_at_ms.desc())
        .limit(1)
    )
    repeated_pressure = False
    if previous is not None and event_rows:
        previous_events = list(
            session.scalars(
                select(RiskEvent).where(
                    RiskEvent.started_at_ms >= previous.started_at_ms,
                    RiskEvent.started_at_ms < reset_at,
                    RiskEvent.risk_type != "temperature_asymmetry",
                )
            )
        )
        repeated_pressure = bool(
            {row.risk_type for row in event_rows}
            & {row.risk_type for row in previous_events}
        )
    if (
        repeated_pressure
        or any(row.step_count >= 18 and row.load_asymmetry >= 0.30 for row in gait_rows)
        or temp.real_consecutive_days >= 4
    ):
        level = 3
    if repeated_pressure:
        evidence.append("最近两次穿戴会话出现同类持续压力异常")
    if not gait_rows:
        quality.append("本次没有完整行走段证据")
    if not temp.real_days:
        quality.append("没有真实温度自然日记录")
    return _rating(level, evidence, quality, session_id=_current_session_id(session))


def assessment_summary(session: Session) -> AssessmentSummary:
    current = save_session_snapshot(session)
    state = session.get(CalibrationState, "personal_baseline")
    reset_at = state.reset_at_ms if state and state.reset_at_ms else None
    previous = session.scalar(
        select(MonitoringSession)
        .where(MonitoringSession.session_id != (current.session_id or ""))
        .order_by(MonitoringSession.started_at_ms.desc())
        .limit(1)
    )
    previous_rating = None
    if previous is not None:
        try:
            raw = json.loads(previous.summary_json or "{}")
            previous_rating = MonitoringRatingSummary.model_validate(raw)
        except (ValueError, json.JSONDecodeError):
            previous_rating = None
    return AssessmentSummary(
        rating=current,
        previous_rating=previous_rating,
        temperature=temperature_evidence(session, after_ms=reset_at),
        health_profile=health_profile(session),
        glucose_readings=glucose_readings(session),
    )


def save_session_snapshot(session: Session) -> MonitoringRatingSummary:
    rating = current_rating(session)
    if rating.session_id is None:
        return rating
    previous = session.scalar(
        select(MonitoringSession)
        .where(MonitoringSession.session_id != rating.session_id)
        .order_by(MonitoringSession.started_at_ms.desc())
        .limit(1)
    )
    if previous is not None:
        previous_level = previous.rating_level
        if rating.rating == "insufficient_data" or previous.rating == "insufficient_data":
            trend, label = "insufficient_data", "任一会话数据不足，无法可靠比较"
        elif rating.level < previous_level:
            trend, label = "improving", "较上次会话好转"
        elif rating.level > previous_level:
            trend, label = "worsening", "较上次会话加重"
        else:
            trend, label = "stable", "与上次会话基本稳定"
        rating = rating.model_copy(
            update={
                "trend": trend,
                "trend_label": label,
                "previous_session_id": previous.session_id,
            }
        )
    state = session.get(CalibrationState, "personal_baseline")
    started = state.reset_at_ms if state and state.reset_at_ms else 0
    row = session.get(MonitoringSession, rating.session_id)
    if row is None:
        row = MonitoringSession(
            session_id=rating.session_id,
            started_at_ms=started,
            data_source="ble",
        )
        session.add(row)
    row.rating = rating.rating
    row.rating_level = rating.level
    row.summary_json = rating.model_dump_json()
    row.ended_at_ms = max(
        (frame.timestamp_ms for frame in session.scalars(
            select(SensorFrame).where(SensorFrame.timestamp_ms >= started)
        )),
        default=started,
    )
    session.commit()
    return rating


def start_temperature_demo(session: Session, now_ms: int) -> TemperatureDemoState:
    session.execute(delete(TemperatureDailyRecord).where(TemperatureDailyRecord.source == "demo"))
    current_date = datetime.fromtimestamp(now_ms / 1000, tz=timezone.utc).date()
    demo_session_id = f"temp_demo_{uuid4().hex[:16]}"
    # Keep one explicit, audience-facing demonstration observation ready. The
    # live event from the right T4 sensor updates this same row when detected.
    session.add(
        TemperatureDailyRecord(
            record_id=f"temp_demo_{current_date}_right_T4",
            record_date=current_date.isoformat(),
            side="right",
            zone="T4",
            raw_delta_c=3.0,
            corrected_delta_c=3.0,
            started_at_ms=now_ms,
            ended_at_ms=now_ms,
            valid_zone_count=4,
            source="demo",
            load_state="unloaded",
            motion_state="stationary",
            quality="prepared_demo",
            demo_session_id=demo_session_id,
        )
    )
    state = session.get(TemperatureDemoState, DEMO_STATE_KEY)
    if state is None:
        state = TemperatureDemoState(
            state_key=DEMO_STATE_KEY,
            demo_session_id=demo_session_id,
            started_at_ms=now_ms,
            seed_date=current_date.isoformat(),
            current_date=current_date.isoformat(),
            status="ready",
        )
        session.add(state)
    else:
        state.demo_session_id = demo_session_id
        state.started_at_ms = now_ms
        state.seed_date = current_date.isoformat()
        state.current_date = current_date.isoformat()
        state.status = "ready"
    session.commit()
    session.refresh(state)
    return state


def reset_temperature_demo(session: Session) -> None:
    session.execute(delete(TemperatureDailyRecord).where(TemperatureDailyRecord.source == "demo"))
    state = session.get(TemperatureDemoState, DEMO_STATE_KEY)
    if state is not None:
        session.delete(state)
    session.commit()


def active_temperature_demo(session: Session) -> TemperatureDemoState | None:
    return session.get(TemperatureDemoState, DEMO_STATE_KEY)


def record_temperature_event(
    session: Session,
    *,
    timestamp_ms: int,
    side: str,
    zone: str,
    raw_delta_c: float,
    corrected_delta_c: float,
    valid_zone_count: int,
    started_at_ms: int,
    source: str = "device_observation",
    load_state: str = "unknown",
    motion_state: str = "unknown",
    quality: str = "usable",
) -> None:
    demo = active_temperature_demo(session) if source == "demo" else None
    date = _date_for(timestamp_ms)
    key = f"temp_{source}_{date}_{side}_{zone}"
    row = session.get(TemperatureDailyRecord, key)
    if row is None:
        row = TemperatureDailyRecord(
            record_id=key,
            record_date=date,
            side=side,
            zone=zone,
            raw_delta_c=raw_delta_c,
            corrected_delta_c=corrected_delta_c,
            started_at_ms=started_at_ms,
            ended_at_ms=timestamp_ms,
            valid_zone_count=valid_zone_count,
            source=source,
            load_state=load_state,
            motion_state=motion_state,
            quality=quality,
            demo_session_id=demo.demo_session_id if demo else None,
        )
        session.add(row)
    elif demo is not None and row.quality == "prepared_demo":
        row.raw_delta_c = raw_delta_c
        row.corrected_delta_c = corrected_delta_c
        row.started_at_ms = started_at_ms
        row.ended_at_ms = timestamp_ms
        row.valid_zone_count = valid_zone_count
        row.load_state = load_state
        row.motion_state = motion_state
        row.quality = quality
        row.demo_session_id = demo.demo_session_id
    elif abs(corrected_delta_c) > abs(row.corrected_delta_c):
        row.raw_delta_c = raw_delta_c
        row.corrected_delta_c = corrected_delta_c
        row.started_at_ms = started_at_ms
        row.ended_at_ms = timestamp_ms
        row.valid_zone_count = valid_zone_count
        row.load_state = load_state
        row.motion_state = motion_state
    if demo is not None:
        demo.status = "completed"
    session.commit()
