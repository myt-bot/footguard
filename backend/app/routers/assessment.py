from __future__ import annotations

from time import time

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import (
    GlucoseReading as GlucoseReadingModel,
    HealthProfile as HealthProfileModel,
    MonitoringSession,
)
from ..schemas import (
    AssessmentSummary,
    GlucoseReading,
    GlucoseReadingCreate,
    HealthProfile,
    HealthProfileUpdate,
    MonitoringRatingSummary,
    TemperatureDailyRecordOut,
    TemperatureDemoResponse,
)
from ..services.assessment_service import (
    DEMO_STATE_KEY,
    HEALTH_PROFILE_KEY,
    active_temperature_demo,
    assessment_summary,
    current_rating,
    glucose_readings,
    health_profile,
    reset_temperature_demo,
    start_temperature_demo,
    temperature_records,
)

router = APIRouter(prefix="/api/v1", tags=["assessment"])


def _demo_response(session: Session) -> TemperatureDemoResponse:
    state = active_temperature_demo(session)
    return TemperatureDemoResponse(
        active=state is not None,
        demo_session_id=state.demo_session_id if state else None,
        seed_date=state.seed_date if state else None,
        current_date=state.current_date if state else None,
        status=state.status if state else "inactive",
    )


@router.get("/assessment/latest", response_model=AssessmentSummary)
def latest_assessment(session: Session = Depends(get_db)) -> AssessmentSummary:
    return assessment_summary(session)


@router.get("/assessment/history", response_model=list[MonitoringRatingSummary])
def assessment_history(session: Session = Depends(get_db)) -> list[MonitoringRatingSummary]:
    rows = list(
        session.scalars(
            select(MonitoringSession).order_by(MonitoringSession.started_at_ms.desc()).limit(30)
        )
    )
    result = []
    for row in rows:
        try:
            result.append(MonitoringRatingSummary.model_validate_json(row.summary_json))
        except ValueError:
            continue
    return result


@router.get("/temperature/daily", response_model=list[TemperatureDailyRecordOut])
def daily_temperature_records(session: Session = Depends(get_db)) -> list[TemperatureDailyRecordOut]:
    return temperature_records(session)


@router.post("/temperature-demo/start", response_model=TemperatureDemoResponse)
def start_demo(session: Session = Depends(get_db)) -> TemperatureDemoResponse:
    start_temperature_demo(session, int(time() * 1000))
    return _demo_response(session)


@router.post("/temperature-demo/reset", response_model=TemperatureDemoResponse)
def reset_demo(session: Session = Depends(get_db)) -> TemperatureDemoResponse:
    reset_temperature_demo(session)
    return _demo_response(session)


@router.get("/health-profile", response_model=HealthProfile)
def get_health_profile(session: Session = Depends(get_db)) -> HealthProfile:
    return health_profile(session)


@router.put("/health-profile", response_model=HealthProfile)
def update_health_profile(
    payload: HealthProfileUpdate, session: Session = Depends(get_db)
) -> HealthProfile:
    row = session.get(HealthProfileModel, HEALTH_PROFILE_KEY)
    if row is None:
        row = HealthProfileModel(
            profile_key=HEALTH_PROFILE_KEY,
            ulcer_or_amputation=payload.ulcer_or_amputation,
            sensory_or_circulation_issue=payload.sensory_or_circulation_issue,
            updated_at_ms=int(time() * 1000),
        )
        session.add(row)
    else:
        row.ulcer_or_amputation = payload.ulcer_or_amputation
        row.sensory_or_circulation_issue = payload.sensory_or_circulation_issue
        row.updated_at_ms = int(time() * 1000)
    session.commit()
    return health_profile(session)


@router.get("/glucose", response_model=list[GlucoseReading])
def get_glucose(session: Session = Depends(get_db)) -> list[GlucoseReading]:
    return glucose_readings(session)


@router.post("/glucose", response_model=GlucoseReading)
def add_glucose(
    payload: GlucoseReadingCreate, session: Session = Depends(get_db)
) -> GlucoseReading:
    row = GlucoseReadingModel(
        reading_id=f"glucose_{int(time() * 1000)}",
        value=payload.value,
        unit=payload.unit,
        context=payload.context,
        measured_at_ms=payload.measured_at_ms,
        note=payload.note,
    )
    session.add(row)
    session.commit()
    return GlucoseReading.model_validate(row, from_attributes=True)
