from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..schemas import RealtimeResponse
from ..services.pairing_service import realtime_snapshot

router = APIRouter(prefix="/api/v1", tags=["realtime"])


@router.get("/realtime", response_model=RealtimeResponse)
def realtime(session: Session = Depends(get_db)) -> RealtimeResponse:
    return realtime_snapshot(session)
