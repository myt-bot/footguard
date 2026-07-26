from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..database import get_db
from ..schemas import CalibrationStatus
from ..services.risk_service import calibration_status, restart_calibration

router = APIRouter(prefix="/api/v1/calibration", tags=["calibration"])


@router.get("/status", response_model=CalibrationStatus)
def get_calibration_status(
    session: Session = Depends(get_db),
) -> CalibrationStatus:
    return calibration_status(session)


@router.post("/reset", response_model=CalibrationStatus)
def reset_personal_baseline(
    session: Session = Depends(get_db),
) -> CalibrationStatus:
    return restart_calibration(session)
