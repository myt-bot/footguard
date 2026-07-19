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


def active_event(session: Session) -> RiskEvent | None:
    return session.scalar(
        select(RiskEvent)
        .where(RiskEvent.status == "active")
        .order_by(RiskEvent.started_at_ms.desc())
        .limit(1)
    )


def feedback_for_event(session: Session, event_id: str) -> InterventionFeedback | None:
    return session.scalar(
        select(InterventionFeedback)
        .where(InterventionFeedback.event_id == event_id)
        .order_by(InterventionFeedback.id.desc())
        .limit(1)
    )
