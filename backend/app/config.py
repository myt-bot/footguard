from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "backend" / "data"
DEFAULT_DATABASE_URL = f"sqlite:///{(DATA_DIR / 'footguard.db').as_posix()}"

# Competition prototype thresholds. These are engineering defaults, not medical standards.
PAIRING_WINDOW_MS = 50
CONTINUITY_GAP_MS = 1_000
PRESSURE_INVALID_MASK = 0x0000003F
TEMPERATURE_INVALID_MASK = 0x000003C0
TIME_UNSYNCED_MASK = 0x00000800
IMU_INVALID_MASK = 0x00000400
CALIBRATION_INVALID_MASK = 0x00002000
SENSOR_STUCK_MASK = 0x00004000
PAIRING_BLOCK_FLAGS = (
    PRESSURE_INVALID_MASK
    | TEMPERATURE_INVALID_MASK
    | TIME_UNSYNCED_MASK
    | CALIBRATION_INVALID_MASK
    | SENSOR_STUCK_MASK
)
LOAD_BIAS_ENTER_THRESHOLD = 0.20
LOAD_BIAS_EXIT_THRESHOLD = 0.12
# Five 5-Hz frames provide about one second of robust pressure smoothing.
PRESSURE_SMOOTHING_WINDOW_SAMPLES = 5
# Ignore a regional left/right comparison when the two matching channels
# contain too little physical pressure evidence. This prevents tiny ADC
# residuals from becoming a visually severe 100% asymmetry.
REGIONAL_MIN_CHANNEL_EVIDENCE = 0.010
REGIONAL_MIN_VISIBLE_SCORE = 0.12
# Pressure decisions use dimensionless ratios and change from a personal
# baseline. Raw sensor values are never compared directly with body-weight
# dependent alarm thresholds.
# Automatic personal-baseline calibration. A candidate must look like
# bilateral weight-bearing rather than off-ground noise or a single-point
# bench press. These are prototype engineering limits, not diagnostic limits.
BASELINE_MIN_SAMPLES = 15
BASELINE_CALIBRATION_WINDOW_SAMPLES = 50
BASELINE_MIN_FOOT_PRESSURE = 0.08
# Do not classify pressure or temperature risk while the footwear is not
# meaningfully loaded. This remains low enough for near-single-foot loading.
RISK_MIN_TOTAL_PRESSURE = 0.08
BASELINE_ACTIVE_PRESSURE_FLOOR = 0.005
BASELINE_MIN_ACTIVE_CHANNELS = 3
BASELINE_BALANCED_BIAS_MAX = 0.50
BASELINE_MAX_TEMPERATURE_DELTA_C = 4.0
# MPU only gates personal-baseline sampling. Pressure and temperature risk
# detection remains active while walking. Missing MPU data fails open.
IMU_GRAVITY_MS2 = 9.80665
IMU_ACCEL_STATIONARY_TOLERANCE_MS2 = 3.0
IMU_GYRO_STATIONARY_THRESHOLD_DPS = 25.0
BASELINE_LOAD_BIAS_INLIER_TOLERANCE = 0.20
BASELINE_DISTRIBUTION_INLIER_TOLERANCE = 0.25
BASELINE_TEMPERATURE_INLIER_TOLERANCE_C = 1.5
DEFAULT_PRESSURE_DISTRIBUTION = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)
FOREFOOT_RATIO_DELTA_THRESHOLD = 0.08
FOREFOOT_RATIO_EXIT_THRESHOLD = 0.05
REGIONAL_SHARE_DELTA_FOR_SEVERE = 0.50
REGIONAL_ASYMMETRY_FOR_SEVERE = 0.35
# A large raw same-region difference must always agree with the value shown
# in the App. The baseline-corrected threshold remains more sensitive.
TEMPERATURE_RAW_DELTA_C_THRESHOLD = 2.5
TEMPERATURE_RAW_DELTA_C_EXIT_THRESHOLD = 2.0
TEMPERATURE_DELTA_C_THRESHOLD = 2.0
TEMPERATURE_DELTA_C_EXIT_THRESHOLD = 1.5
# Real NTC/contact readings can briefly dip for one or two 5-Hz frames. Keep
# an established temperature episode alive across that short dropout, while a
# genuine recovery still clears promptly.
TEMPERATURE_DROPOUT_GRACE_MS = 1_200
ATTENTION_AFTER_MS = 3_000
WARNING_AFTER_MS = 6_000
PERSISTENT_AFTER_MS = 10_000
MOTOR_COMMAND_LEVEL = 2
MOTOR_WARNING_PATTERN = "double"
MOTOR_WARNING_DURATION_MS = 800
MOTOR_PERSISTENT_PATTERN = "long"
MOTOR_PERSISTENT_DURATION_MS = 1_500
# Human-facing competition demo: leave enough time for the App polling cycle
# and for the user to press the simulated execution button.
MOTOR_COMMAND_TTL_MS = 30_000
RECOVERY_EFFECTIVE_RATIO = 0.50
RECOVERY_PARTIAL_RATIO = 0.20
RECOVERY_OBSERVATION_MS = 15_000


def database_url() -> str:
    return os.getenv("FOOTGUARD_DATABASE_URL", DEFAULT_DATABASE_URL)


def ai_provider() -> str:
    return os.getenv("FOOTGUARD_AI_PROVIDER", "mock").strip().lower()


def ai_base_url() -> str:
    return os.getenv("FOOTGUARD_AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")


def ai_api_key() -> str:
    return os.getenv("FOOTGUARD_AI_API_KEY", "").strip()


def ai_model() -> str:
    return os.getenv("FOOTGUARD_AI_MODEL", "").strip()


def ai_timeout_seconds() -> float:
    raw_value = os.getenv("FOOTGUARD_AI_TIMEOUT_SECONDS", "15")
    try:
        value = float(raw_value)
    except ValueError:
        return 15.0
    return min(max(value, 1.0), 60.0)
