from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..models import CalibrationState, SensorFrame


BASELINE_STATE_KEY = "personal_baseline"


def calibration_state(session: Session) -> CalibrationState | None:
    return session.get(CalibrationState, BASELINE_STATE_KEY)


def calibration_frame_cutoff(session: Session) -> int:
    state = calibration_state(session)
    return state.reset_after_frame_id if state is not None else 0


def reset_calibration(session: Session, reset_at_ms: int) -> CalibrationState:
    latest_frame_id = session.scalar(select(func.max(SensorFrame.id))) or 0
    state = calibration_state(session)
    if state is None:
        state = CalibrationState(
            state_key=BASELINE_STATE_KEY,
            reset_after_frame_id=latest_frame_id,
            reset_at_ms=reset_at_ms,
        )
        session.add(state)
    else:
        state.reset_after_frame_id = latest_frame_id
        state.reset_at_ms = reset_at_ms
    session.commit()
    session.refresh(state)
    return state
