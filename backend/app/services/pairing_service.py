from __future__ import annotations

from sqlalchemy.orm import Session

from ..repositories.sensor_repository import latest_frame, to_schema
from ..schemas import RealtimeResponse, RiskState

PAIRING_WINDOW_MS = 50
PAIRING_BLOCK_FLAGS = 0x0000143F  # pressure invalid, time unsynced, calibration invalid


def realtime_snapshot(session: Session) -> RealtimeResponse:
    left_model = latest_frame(session, "left")
    right_model = latest_frame(session, "right")
    left = to_schema(left_model) if left_model else None
    right = to_schema(right_model) if right_model else None
    incomplete = (
        left is None
        or right is None
        or left.sync_id == 0
        or left.sync_id != right.sync_id
        or bool((left.quality_flags | right.quality_flags) & PAIRING_BLOCK_FLAGS)
        or abs(left.timestamp_ms - right.timestamp_ms) > PAIRING_WINDOW_MS
    )
    if incomplete:
        return RealtimeResponse(
            left=left,
            right=right,
            paired_timestamp_ms=None,
            sync_error_ms=None,
            load_bias=None,
            load_diff=None,
            risk=RiskState(
                risk_type="data_incomplete", risk_side="none", risk_level=0, duration_ms=0
            ),
        )

    left_load = sum(left.pressure)
    right_load = sum(right.pressure)
    total = left_load + right_load
    load_diff = abs(left_load - right_load)
    load_bias = 0.0 if total == 0 else (left_load - right_load) / total
    return RealtimeResponse(
        left=left,
        right=right,
        paired_timestamp_ms=max(left.timestamp_ms, right.timestamp_ms),
        sync_error_ms=abs(left.timestamp_ms - right.timestamp_ms),
        load_bias=load_bias,
        load_diff=load_diff,
        risk=RiskState(risk_type="normal", risk_side="none", risk_level=0, duration_ms=0),
    )
