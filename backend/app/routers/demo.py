from __future__ import annotations

import csv
from pathlib import Path
from time import time

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.sensor_repository import add_frames
from ..schemas import FootFrame, ImuData, SensorBatchResponse
from ..services.risk_service import evaluate_risk, restart_calibration

router = APIRouter(prefix="/api/v1/demo", tags=["demo"])
SAMPLE_DIR = Path(__file__).resolve().parents[3] / "mobile_app" / "assets" / "sample_data"
SCENARIOS = {
    "normal_stand": "normal_stand.csv",
    "left_load_bias": "left_load_bias.csv",
    "right_load_bias": "right_load_bias.csv",
    "left_forefoot_high": "left_forefoot_high.csv",
    "left_temperature_rise": "left_temperature_rise.csv",
    "intervention_recovery": "intervention_recovery.csv",
}


def _frame(
    row: dict[str, str],
    *,
    run_sync_id: int,
    timestamp_offset_ms: int,
) -> FootFrame:
    return FootFrame(
        protocol_version=1,
        sensor_layout_version="layout_6p4t_v1",
        device_id=row["device_id"],
        side=row["side"],
        sync_id=run_sync_id,
        packet_seq=int(row["packet_seq"]),
        timestamp_ms=int(row["timestamp_ms"]) + timestamp_offset_ms,
        pressure=[float(row[f"p{index}"]) for index in range(1, 7)],
        temperature=[float(row[f"t{index}"]) for index in range(1, 5)],
        imu=ImuData(**{name: float(row[name]) for name in ("ax", "ay", "az", "gx", "gy", "gz")}),
        battery=int(row["battery"]),
        quality_flags=int(row["quality_flags"]),
        source="csv_replay",
    )


@router.post("/replay", response_model=SensorBatchResponse)
def replay_demo(
    scenario: str = Query(default="intervention_recovery"),
    session: Session = Depends(get_db),
) -> SensorBatchResponse:
    filename = SCENARIOS.get(scenario)
    if filename is None:
        raise HTTPException(status_code=400, detail="unsupported demo scenario")
    restart_calibration(session)
    rows = list(csv.DictReader((SAMPLE_DIR / filename).open(encoding="utf-8-sig")))
    first_timestamp_ms = int(rows[0]["timestamp_ms"])
    now_ms = int(time() * 1000)
    timestamp_offset_ms = now_ms - first_timestamp_ms
    run_sync_id = now_ms & 0xFFFFFFFF
    accepted = 0
    rejected = 0
    latest = None
    for index in range(0, len(rows), 2):
        frames = [
            _frame(
                row,
                run_sync_id=run_sync_id,
                timestamp_offset_ms=timestamp_offset_ms,
            )
            for row in rows[index : index + 2]
        ]
        pair_accepted, pair_rejected = add_frames(session, frames)
        accepted += pair_accepted
        rejected += pair_rejected
        if pair_accepted:
            latest = evaluate_risk(session, record=True, allow_motor_command=False)
    latest = latest or evaluate_risk(session)
    return SensorBatchResponse(
        accepted=accepted,
        rejected=rejected,
        latest_risk=latest.risk.risk_type,
    )
