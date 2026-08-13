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
    ordered_groups = sorted(
        groups.items(), key=lambda item: max(frame.timestamp_ms for frame in item[1])
    )
    ordered_frames = [
        frame for _, frames in ordered_groups for frame in frames
    ]
    accepted, rejected = add_frames(session, ordered_frames)
    if not ordered_frames:
        latest = evaluate_risk(session)
    else:
        # Risk duration is derived from frame timestamps, so one evaluation of
        # the newest pair preserves the episode while avoiding an expensive
        # full-history scan for every pair in an Android backlog batch.
        latest = evaluate_risk(
            session, record=True, allow_motor_command=True
        )
    return SensorBatchResponse(
        accepted=accepted,
        rejected=rejected,
        latest_risk=latest.risk.risk_type,
    )
