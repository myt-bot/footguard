from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.sensor_repository import add_frames
from ..schemas import SensorBatchRequest, SensorBatchResponse
from ..services.pairing_service import realtime_snapshot

router = APIRouter(prefix="/api/v1/sensor", tags=["sensor"])


@router.post("/batch", response_model=SensorBatchResponse)
def ingest_batch(
    payload: SensorBatchRequest, session: Session = Depends(get_db)
) -> SensorBatchResponse:
    accepted, rejected = add_frames(session, payload.frames)
    return SensorBatchResponse(
        accepted=accepted,
        rejected=rejected,
        latest_risk=realtime_snapshot(session).risk.risk_type,
    )
