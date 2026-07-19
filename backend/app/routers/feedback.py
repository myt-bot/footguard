from time import time

from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.event_repository import add_feedback
from ..schemas import InterventionFeedbackRequest, RecordedResponse

router = APIRouter(prefix="/api/v1", tags=["feedback"])


@router.post(
    "/intervention/feedback",
    response_model=RecordedResponse,
    status_code=status.HTTP_201_CREATED,
)
def record_feedback(
    payload: InterventionFeedbackRequest, session: Session = Depends(get_db)
) -> RecordedResponse:
    add_feedback(session, payload, int(time() * 1000))
    return RecordedResponse(recorded=True)
