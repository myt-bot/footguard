import json

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import Command, CommandAck, InterventionFeedback, RiskEvent
from ..repositories.sensor_repository import add_frames
from ..schemas import (
    OfflineInterventionBatch,
    OfflineInterventionResponse,
    SensorBatchRequest,
    SensorBatchResponse,
)
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


@router.post("/offline-sync", response_model=SensorBatchResponse)
def ingest_offline_batch(
    payload: SensorBatchRequest, session: Session = Depends(get_db)
) -> SensorBatchResponse:
    """Archive a disconnected App backlog without rewriting live risk state.

    Offline risk events and intervention results are uploaded separately by
    ``/offline-interventions``. Re-evaluating every historical frame pair here
    would run the live engine against the database's newest pair and could
    corrupt event times when old and new data arrive out of order.
    """
    groups: dict[tuple[int, int], list] = {}
    for frame in payload.frames:
        groups.setdefault((frame.sync_id, frame.packet_seq), []).append(frame)
    ordered_groups = sorted(
        groups.values(), key=lambda frames: max(frame.timestamp_ms for frame in frames)
    )
    ordered_frames = [frame for frames in ordered_groups for frame in frames]
    accepted, rejected = add_frames(session, ordered_frames)
    latest = evaluate_risk(session)
    return SensorBatchResponse(
        accepted=accepted,
        rejected=rejected,
        latest_risk=latest.risk.risk_type,
    )


@router.post("/offline-interventions", response_model=OfflineInterventionResponse)
def ingest_offline_interventions(
    payload: OfflineInterventionBatch,
    session: Session = Depends(get_db),
) -> OfflineInterventionResponse:
    accepted = 0
    rejected = 0
    for record in payload.records:
        if session.get(Command, record.command.command_id) is not None:
            rejected += 1
            continue
        primary = record.risk
        event = session.get(RiskEvent, record.event_id)
        if event is None:
            event = RiskEvent(
                event_id=record.event_id,
                risk_type=primary.risk_type,
                risk_side=primary.risk_side,
                risk_level=primary.risk_level,
                started_at_ms=record.started_at_ms,
                duration_ms=primary.duration_ms,
                before_load_diff=None,
                after_load_diff=None,
                status="interrupted",
                risk_components_json=json.dumps(
                    [item.model_dump(mode="json") for item in record.active_risks],
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            )
            session.add(event)
        command = Command(
            command_id=record.command.command_id,
            event_id=record.event_id,
            protocol_version=1,
            target=record.command.target,
            pattern=record.command.pattern,
            duration_ms=record.command.duration_ms,
            expire_at_ms=record.command.expire_at_ms,
            reason_code=record.command.reason_code,
            status="executed" if any(ack.status == "executed" for ack in record.acknowledgements) else "failed",
            created_at_ms=record.started_at_ms,
            executed_at_ms=max((ack.executed_at_ms or 0 for ack in record.acknowledgements), default=0) or None,
            ack_at_ms=max((ack.ack_at_ms for ack in record.acknowledgements), default=0) or None,
            error_code="none" if record.acknowledgements else "command_expired",
        )
        session.add(command)
        for ack in record.acknowledgements:
            session.add(CommandAck(
                command_id=ack.command_id,
                device_id=ack.device_id,
                status=ack.status,
                ack_at_ms=ack.ack_at_ms,
                executed_at_ms=ack.executed_at_ms,
                error_code=ack.error_code,
            ))
        if (
            record.effect_label is not None
            and record.before_load_diff is not None
            and record.after_load_diff is not None
        ):
            session.add(InterventionFeedback(
                event_id=record.event_id,
                user_action="offline_motor_vibration",
                effect_label=record.effect_label,
                before_load_diff=record.before_load_diff,
                after_load_diff=record.after_load_diff,
                recovery_time_ms=record.recovery_time_ms or 15_000,
                created_at_ms=max((ack.ack_at_ms for ack in record.acknowledgements), default=record.started_at_ms),
            ))
        accepted += 1
    session.commit()
    return OfflineInterventionResponse(accepted=accepted, rejected=rejected)
