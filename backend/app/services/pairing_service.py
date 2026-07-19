from __future__ import annotations

from sqlalchemy.orm import Session

from ..schemas import RealtimeResponse
from .risk_service import evaluate_risk


def realtime_snapshot(session: Session) -> RealtimeResponse:
    return evaluate_risk(session)
