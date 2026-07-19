from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ImuData(StrictModel):
    ax: float
    ay: float
    az: float
    gx: float
    gy: float
    gz: float


class FootFrame(StrictModel):
    protocol_version: Literal[1]
    sensor_layout_version: Literal["layout_6p3t_v1"]
    device_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,16}$")
    side: Literal["left", "right"]
    sync_id: int = Field(ge=0, le=4294967295)
    packet_seq: int = Field(ge=0, le=4294967295)
    timestamp_ms: int = Field(ge=0)
    pressure: list[float] = Field(min_length=6, max_length=6)
    temperature: list[float] = Field(min_length=3, max_length=3)
    imu: ImuData
    battery: int = Field(ge=0, le=100)
    quality_flags: int = Field(ge=0, le=4294967295)
    source: Literal["mock", "csv_replay", "ble"]

    @field_validator("pressure")
    @classmethod
    def pressure_range(cls, values: list[float]) -> list[float]:
        if any(not 0.0 <= value <= 1.0 for value in values):
            raise ValueError("pressure values must be between 0.0 and 1.0")
        return values

    @field_validator("temperature")
    @classmethod
    def temperature_range(cls, values: list[float]) -> list[float]:
        if any(not -40.0 <= value <= 125.0 for value in values):
            raise ValueError("temperature values must be between -40.0 and 125.0")
        return values

    @model_validator(mode="after")
    def check_sync_and_reserved_flags(self) -> "FootFrame":
        if self.quality_flags & 0xFFFF8000:
            raise ValueError("quality_flags reserved bits must be zero")
        if self.sync_id == 0 and (
            self.timestamp_ms != 0 or not self.quality_flags & 0x00000400
        ):
            raise ValueError("unsynced frame requires timestamp_ms=0 and TIME_UNSYNCED")
        return self


class SensorBatchRequest(StrictModel):
    protocol_version: Literal[1]
    app_received_at_ms: int = Field(ge=0)
    frames: list[FootFrame]


class SensorBatchResponse(StrictModel):
    accepted: int
    rejected: int
    latest_risk: str


class RiskState(StrictModel):
    risk_type: Literal[
        "normal", "left_load_bias", "right_load_bias", "forefoot_high", "data_incomplete"
    ]
    risk_side: Literal["left", "right", "both", "none"]
    risk_level: int = Field(ge=0, le=3)
    duration_ms: int = Field(ge=0)


class RealtimeResponse(StrictModel):
    left: FootFrame | None
    right: FootFrame | None
    paired_timestamp_ms: int | None
    sync_error_ms: int | None
    load_bias: float | None
    load_diff: float | None
    risk: RiskState


class DeviceCommand(StrictModel):
    protocol_version: Literal[1] = 1
    command_id: str = Field(pattern=r"^cmd_[A-Za-z0-9_-]{1,48}$")
    target: Literal["left", "right", "both"]
    pattern: Literal["off", "short", "double", "long"]
    duration_ms: int = Field(ge=0, le=5000)
    expire_at_ms: int = Field(ge=0)
    reason_code: Literal[
        "manual_test",
        "left_load_bias",
        "right_load_bias",
        "forefoot_high",
        "risk_persisted",
        "cancel",
    ]

    @model_validator(mode="after")
    def validate_pattern_duration(self) -> "DeviceCommand":
        ranges = {"off": (0, 0), "short": (100, 1000), "double": (200, 2000), "long": (1000, 5000)}
        minimum, maximum = ranges[self.pattern]
        if not minimum <= self.duration_ms <= maximum:
            raise ValueError(f"duration_ms for {self.pattern} must be {minimum}..{maximum}")
        return self


class PendingCommandResponse(StrictModel):
    command: DeviceCommand | None


class AckRequest(StrictModel):
    protocol_version: Literal[1]
    command_id: str = Field(pattern=r"^cmd_[A-Za-z0-9_-]{1,48}$")
    device_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,16}$")
    status: Literal["executed", "rejected", "expired", "failed"]
    ack_at_ms: int = Field(ge=0)
    executed_at_ms: int | None = Field(default=None, ge=0)
    error_code: Literal[
        "none",
        "invalid_json",
        "unsupported_protocol",
        "target_mismatch",
        "invalid_pattern",
        "invalid_duration",
        "command_expired",
        "time_unsynced",
        "motor_fault",
        "command_conflict",
        "internal_error",
    ]

    @model_validator(mode="after")
    def validate_ack_state(self) -> "AckRequest":
        if self.status == "executed":
            if self.executed_at_ms is None or self.error_code != "none":
                raise ValueError("executed ACK requires executed_at_ms and error_code=none")
        elif self.executed_at_ms is not None:
            raise ValueError("non-executed ACK must not contain executed_at_ms")
        return self


class RecordedResponse(StrictModel):
    recorded: bool


class RiskEventOut(StrictModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)
    event_id: str
    risk_type: str
    risk_side: str
    risk_level: int
    started_at_ms: int
    ended_at_ms: int | None
    duration_ms: int
    before_load_diff: float | None
    after_load_diff: float | None
    status: str


class InterventionFeedbackRequest(StrictModel):
    event_id: str = Field(min_length=1, max_length=64)
    user_action: str = Field(min_length=1, max_length=64)
    effect_label: Literal["effective", "partial", "ineffective", "unknown"]
    before_load_diff: float = Field(ge=0)
    after_load_diff: float = Field(ge=0)
    recovery_time_ms: int = Field(ge=0)
