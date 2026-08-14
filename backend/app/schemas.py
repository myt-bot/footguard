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
    sensor_layout_version: Literal["layout_6p4t_v1"]
    device_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,16}$")
    side: Literal["left", "right"]
    sync_id: int = Field(ge=0, le=4294967295)
    packet_seq: int = Field(ge=0, le=4294967295)
    timestamp_ms: int = Field(ge=0)
    pressure: list[float] = Field(min_length=6, max_length=6)
    temperature: list[float] = Field(min_length=4, max_length=4)
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
        if self.quality_flags & 0xFFFF0000:
            raise ValueError("quality_flags reserved bits must be zero")
        if self.sync_id == 0 and (
            self.timestamp_ms != 0 or not self.quality_flags & 0x00000800
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


class OfflineInterventionRecord(StrictModel):
    event_id: str = Field(pattern=r"^local_evt_[0-9]+$")
    command: "DeviceCommand"
    risk: "RiskState"
    active_risks: list["RiskState"] = Field(default_factory=list)
    started_at_ms: int = Field(ge=0)
    acknowledgements: list["AckRequest"] = Field(default_factory=list)
    before_load_diff: float | None = Field(default=None, ge=0)
    after_load_diff: float | None = Field(default=None, ge=0)
    effect_label: Literal["effective", "partial", "ineffective", "unknown"] | None = None
    recovery_time_ms: int | None = Field(default=None, ge=0)


class OfflineInterventionBatch(StrictModel):
    protocol_version: Literal[1]
    records: list[OfflineInterventionRecord] = Field(max_length=200)


class OfflineInterventionResponse(StrictModel):
    accepted: int = Field(ge=0)
    rejected: int = Field(ge=0)


class RiskState(StrictModel):
    risk_type: Literal[
        "normal",
        "left_load_bias",
        "right_load_bias",
        "forefoot_high",
        "temperature_asymmetry",
        "data_incomplete",
    ]
    risk_side: Literal["left", "right", "both", "none"]
    risk_level: int = Field(ge=0, le=3)
    duration_ms: int = Field(ge=0)


class AiAdviceRequest(StrictModel):
    protocol_version: Literal[1]
    risk: RiskState
    active_risks: list[RiskState] = Field(default_factory=list)
    load_diff: float | None = Field(default=None, ge=0)
    temperature_delta_max_c: float | None = Field(default=None, ge=0)
    baseline_ready: bool = False
    pressure_available: bool = True
    temperature_available: bool = True
    left_connected: bool = True
    right_connected: bool = True


class AiAdviceResponse(StrictModel):
    protocol_version: Literal[1] = 1
    provider: str = Field(min_length=1, max_length=64)
    risk_level: int = Field(ge=0, le=3)
    explanation: str = Field(min_length=1, max_length=500)
    advice: str = Field(min_length=1, max_length=500)
    target: Literal["left", "right", "both", "none"]
    candidate_pattern: Literal["off", "short", "double", "long"]


class AiQuestionRequest(AiAdviceRequest):
    question_key: Literal[
        "risk_reason",
        "immediate_action",
        "improvement_check",
        "when_to_seek_help",
    ]


class AiQuestionResponse(StrictModel):
    protocol_version: Literal[1] = 1
    provider: str = Field(min_length=1, max_length=64)
    question_key: Literal[
        "risk_reason",
        "immediate_action",
        "improvement_check",
        "when_to_seek_help",
    ]
    question: str = Field(min_length=1, max_length=80)
    answer: str = Field(min_length=1, max_length=500)


class AiChatRequest(AiAdviceRequest):
    question: str = Field(min_length=1, max_length=120)
    pressure_available: bool = False
    temperature_available: bool = False
    valid_temperature_pairs: int = Field(default=0, ge=0, le=4)
    motion_state: Literal["stationary", "moving", "unavailable"] = "unavailable"
    left_connected: bool = False
    right_connected: bool = False


class AiChatResponse(StrictModel):
    protocol_version: Literal[1] = 1
    provider: str = Field(min_length=1, max_length=64)
    question: str = Field(min_length=1, max_length=120)
    answer: str = Field(min_length=1, max_length=500)


class RealtimeResponse(StrictModel):
    left: FootFrame | None
    right: FootFrame | None
    paired_timestamp_ms: int | None
    sync_error_ms: int | None
    load_bias: float | None
    load_diff: float | None
    motion_state: Literal["stationary", "moving", "unavailable"] = "unavailable"
    left_motion_state: Literal["stationary", "moving", "unavailable"] = "unavailable"
    right_motion_state: Literal["stationary", "moving", "unavailable"] = "unavailable"
    pressure_available: bool = False
    temperature_available: bool = False
    risk: RiskState
    active_risks: list[RiskState] = Field(default_factory=list)
    regional_analysis: "RegionalAnalysis | None" = None
    recovery_observation: "RecoveryObservation | None" = None


class RecoveryObservation(StrictModel):
    event_id: str
    status: Literal["observing", "completed"]
    started_at_ms: int = Field(ge=0)
    deadline_at_ms: int = Field(ge=0)
    remaining_ms: int = Field(ge=0)
    effect_label: Literal["effective", "partial", "ineffective", "unknown"] | None = None
    component_feedback: list["RiskComponentFeedback"] = Field(default_factory=list)


class RegionalAnalysis(StrictModel):
    baseline_ready: bool
    baseline_source: Literal["personal", "layout_default"]
    baseline_sample_count: int = Field(ge=0)
    baseline_required_samples: int = Field(gt=0)
    left_pressure_scores: list[float] = Field(min_length=6, max_length=6)
    right_pressure_scores: list[float] = Field(min_length=6, max_length=6)
    pressure_available: bool = False
    left_pressure_valid: list[bool] = Field(min_length=6, max_length=6)
    right_pressure_valid: list[bool] = Field(min_length=6, max_length=6)
    left_pressure_baseline_trusted: list[bool] = Field(min_length=6, max_length=6)
    right_pressure_baseline_trusted: list[bool] = Field(min_length=6, max_length=6)
    left_pressure_analysis_valid: list[bool] = Field(min_length=6, max_length=6)
    right_pressure_analysis_valid: list[bool] = Field(min_length=6, max_length=6)
    left_pressure_channel_status: list[
        Literal["ok", "uncovered_in_baseline", "raw_invalid", "residual_suspect"]
    ] = Field(min_length=6, max_length=6)
    right_pressure_channel_status: list[
        Literal["ok", "uncovered_in_baseline", "raw_invalid", "residual_suspect"]
    ] = Field(min_length=6, max_length=6)
    temperature_available: bool = False
    left_temperature_valid: list[bool] = Field(min_length=4, max_length=4)
    right_temperature_valid: list[bool] = Field(min_length=4, max_length=4)
    temperature_delta_c: list[float | None] = Field(min_length=4, max_length=4)
    left_temperature_scores: list[float] = Field(min_length=4, max_length=4)
    right_temperature_scores: list[float] = Field(min_length=4, max_length=4)
    temperature_offset_status: list[str] = Field(min_length=4, max_length=4)
    temperature_offset_channels: list[int] = Field(default_factory=list)
    temperature_untrusted_channels: list[int] = Field(default_factory=list)
    temperature_risk_enabled: bool = False
    temperature_risk_reason: str = "baseline_not_ready"


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
        "temperature_asymmetry",
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


class CalibrationStatus(StrictModel):
    baseline_ready: bool
    sample_count: int = Field(ge=0)
    required_samples: int = Field(gt=0)
    reset_at_ms: int | None = Field(default=None, ge=0)
    status_reason: Literal[
        "ready",
        "waiting_for_data",
        "pressure_unavailable",
        "not_loaded",
        "left_not_loaded",
        "right_not_loaded",
        "pressure_residual",
        "moving",
        "unstable",
        "temperature_reference_learning",
        "temperature_unavailable",
        "temperature_unstable",
    ] = "waiting_for_data"
    empty_temperature_reference_ready: bool = False
    temperature_risk_enabled: bool = False
    temperature_offset_channels: list[int] = Field(default_factory=list)
    temperature_untrusted_channels: list[int] = Field(default_factory=list)
    temperature_risk_reason: str = "baseline_not_ready"


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
    intervention_action: str | None = None
    effect_label: Literal["effective", "partial", "ineffective", "unknown"] | None = None
    recovery_time_ms: int | None = Field(default=None, ge=0)
    status: str
    active_risks: list[RiskState] = Field(default_factory=list)
    intervention_started_at_ms: int | None = Field(default=None, ge=0)
    component_feedback: list["RiskComponentFeedback"] = Field(default_factory=list)


class RiskComponentFeedback(StrictModel):
    risk_type: str
    risk_side: str
    before_value: float | None = None
    after_value: float | None = None
    improvement_ratio: float | None = None
    effect_label: Literal[
        "effective", "partial", "ineffective", "unknown", "observation_only"
    ] = "unknown"
    pressure_intervention: bool = True


class SessionSummary(StrictModel):
    session_status: Literal["live", "recent", "empty"]
    data_source: Literal["ble", "mock", "csv_replay", "none"] = "none"
    last_data_at_ms: int | None = Field(default=None, ge=0)
    baseline_ready: bool = False
    pressure_available: bool = False
    temperature_available: bool = False
    left_device_id: str | None = None
    right_device_id: str | None = None
    left_valid_pressure_channels: int = Field(default=0, ge=0, le=6)
    right_valid_pressure_channels: int = Field(default=0, ge=0, le=6)
    event_count: int = Field(ge=0)
    highest_risk_level: int = Field(ge=0, le=3)
    risk_counts: dict[str, int] = Field(default_factory=dict)
    longest_duration_ms: dict[str, int] = Field(default_factory=dict)
    motor_command_count: int = Field(default=0, ge=0)
    motor_executed_count: int = Field(default=0, ge=0)
    motor_ack_count: int = Field(default=0, ge=0)
    recovery_counts: dict[str, int] = Field(default_factory=dict)
    sensor_summary: dict[str, float] = Field(default_factory=dict)
    latest_events: list[RiskEventOut] = Field(default_factory=list)


class SessionAdviceResponse(StrictModel):
    protocol_version: Literal[1] = 1
    provider: str = Field(min_length=1, max_length=64)
    session_status: Literal["live", "recent", "empty"]
    advice: str = Field(min_length=1, max_length=700)


class InterventionFeedbackRequest(StrictModel):
    event_id: str = Field(min_length=1, max_length=64)
    user_action: str = Field(min_length=1, max_length=64)
    effect_label: Literal["effective", "partial", "ineffective", "unknown"]
    before_load_diff: float = Field(ge=0)
    after_load_diff: float = Field(ge=0)
    recovery_time_ms: int = Field(ge=0)
