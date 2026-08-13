from __future__ import annotations

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from ..models import CalibrationProfile, CalibrationState, SensorFrame


BASELINE_STATE_KEY = "personal_baseline"
BASELINE_PROFILE_KEY = "active_wearing"


def calibration_state(session: Session) -> CalibrationState | None:
    return session.get(CalibrationState, BASELINE_STATE_KEY)


def calibration_frame_cutoff(session: Session) -> int:
    state = calibration_state(session)
    return state.reset_after_frame_id if state is not None else 0


def calibration_profile(session: Session) -> CalibrationProfile | None:
    return session.get(CalibrationProfile, BASELINE_PROFILE_KEY)


def save_calibration_profile(
    session: Session, profile: CalibrationProfile
) -> CalibrationProfile:
    existing = calibration_profile(session)
    if existing is not None:
        session.delete(existing)
        session.flush()
    session.add(profile)
    session.commit()
    session.refresh(profile)
    return profile


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
    session.execute(
        delete(CalibrationProfile).where(
            CalibrationProfile.profile_key == BASELINE_PROFILE_KEY
        )
    )
    session.commit()
    session.refresh(state)
    return state
