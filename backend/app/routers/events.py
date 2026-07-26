from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.event_repository import feedback_for_event, list_events
from ..schemas import RiskEventOut

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
        if feedback is not None:
            item = item.model_copy(
                update={
                    "intervention_action": feedback.user_action,
                    "effect_label": feedback.effect_label,
                    "recovery_time_ms": feedback.recovery_time_ms,
                }
            )
        result.append(item)
    return result
