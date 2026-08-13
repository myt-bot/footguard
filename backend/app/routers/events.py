import json

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.event_repository import feedback_for_event, list_events
from ..schemas import RiskEventOut, RiskState

router = APIRouter(prefix="/api/v1", tags=["events"])


@router.get("/events", response_model=list[RiskEventOut])
def events(
    limit: int = Query(default=50, ge=1, le=200),
    session: Session = Depends(get_db),
) -> list[RiskEventOut]:
    result = []
    for event in list_events(session, limit):
        feedback = feedback_for_event(session, event.event_id)
        item = RiskEventOut.model_validate(event)
        try:
            raw_components = json.loads(event.risk_components_json or "[]")
            active_risks = (
                [RiskState.model_validate(component) for component in raw_components]
                if isinstance(raw_components, list)
                else []
            )
        except (TypeError, ValueError):
            active_risks = []
        if not active_risks:
            active_risks = [
                RiskState(
                    risk_type=event.risk_type,
                    risk_side=event.risk_side,
                    risk_level=event.risk_level,
                    duration_ms=event.duration_ms,
                )
            ]
        item = item.model_copy(update={"active_risks": active_risks})
        if feedback is not None:
            item = item.model_copy(
                update={
                    "before_load_diff": feedback.before_load_diff,
                    "after_load_diff": feedback.after_load_diff,
                    "intervention_action": feedback.user_action,
                    "effect_label": feedback.effect_label,
                    "recovery_time_ms": feedback.recovery_time_ms,
                }
            )
        result.append(item)
    return result
