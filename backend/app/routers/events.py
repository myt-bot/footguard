from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.event_repository import list_events
from ..schemas import RiskEventOut

router = APIRouter(prefix="/api/v1", tags=["events"])


@router.get("/events", response_model=list[RiskEventOut])
def events(
    limit: int = Query(default=50, ge=1, le=200),
    session: Session = Depends(get_db),
) -> list[RiskEventOut]:
    return [RiskEventOut.model_validate(event) for event in list_events(session, limit)]
