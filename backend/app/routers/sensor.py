from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.sensor_repository import add_frames
from ..schemas import SensorBatchRequest, SensorBatchResponse
from ..services.risk_service import evaluate_risk

router = APIRouter(prefix="/api/v1/sensor", tags=["sensor"])


@router.post("/batch", response_model=SensorBatchResponse)
def ingest_batch(
    payload: SensorBatchRequest, session: Session = Depends(get_db)
) -> SensorBatchResponse:
    groups: dict[tuple[int, int], list] = {}
    for frame in payload.frames:
        groups.setdefault((frame.sync_id, frame.packet_seq), []).append(frame)
    accepted = 0
    rejected = 0
    latest = None
    ordered_groups = sorted(
        groups.items(), key=lambda item: max(frame.timestamp_ms for frame in item[1])
    )
    for _, frames in ordered_groups:
        group_accepted, group_rejected = add_frames(session, frames)
        accepted += group_accepted
        rejected += group_rejected
        latest = evaluate_risk(
            session, record=True, allow_motor_command=False
        )
    if latest is None:
        latest = evaluate_risk(session)
    else:
        # Start the short device-command TTL only after the whole upload has finished.
        latest = evaluate_risk(
            session, record=True, allow_motor_command=True
        )
    return SensorBatchResponse(
        accepted=accepted,
        rejected=rejected,
        latest_risk=latest.risk.risk_type,
    )
