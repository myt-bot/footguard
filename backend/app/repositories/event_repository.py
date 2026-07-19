from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import InterventionFeedback, RiskEvent
from ..schemas import InterventionFeedbackRequest


def list_events(session: Session, limit: int) -> list[RiskEvent]:
    return list(
        session.scalars(
            select(RiskEvent).order_by(RiskEvent.started_at_ms.desc()).limit(limit)
        )
    )


def add_feedback(
    session: Session, payload: InterventionFeedbackRequest, created_at_ms: int
) -> InterventionFeedback:
    feedback = InterventionFeedback(**payload.model_dump(), created_at_ms=created_at_ms)
    session.add(feedback)
    session.commit()
    session.refresh(feedback)
    return feedback
