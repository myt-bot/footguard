from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "backend" / "data"
DEFAULT_DATABASE_URL = f"sqlite:///{(DATA_DIR / 'footguard.db').as_posix()}"

# Competition prototype thresholds. These are engineering defaults, not medical standards.
PAIRING_WINDOW_MS = 50
CONTINUITY_GAP_MS = 1_000
# BLE frames are nominally 5 Hz, but a busy Android/backend cycle can deliver
# a retained batch with 1.4 s between stored pairs. This relaxed gap applies
# only after a valid bilateral pair exists; disconnect freshness stays strict.
RISK_CONTINUITY_GAP_MS = 1_800
RISK_EVENT_CLEAR_HOLD_MS = 5_000
PRESSURE_INVALID_MASK = 0x0000003F
TEMPERATURE_INVALID_MASK = 0x000003C0
TIME_UNSYNCED_MASK = 0x00000800
IMU_INVALID_MASK = 0x00000400
CALIBRATION_INVALID_MASK = 0x00002000
SENSOR_STUCK_MASK = 0x00004000
PAIRING_BLOCK_FLAGS = TIME_UNSYNCED_MASK | SENSOR_STUCK_MASK
PRESSURE_BLOCK_FLAGS = PRESSURE_INVALID_MASK | CALIBRATION_INVALID_MASK
# Runtime pressure decisions may tolerate one or two explicitly invalid
# channels. Personal-baseline learning remains stricter and requires all six.
PRESSURE_MIN_VALID_CHANNELS_PER_FOOT = 4
FOREFOOT_MIN_VALID_CHANNELS = 2
REARFOOT_MIN_VALID_CHANNELS = 1
FOREFOOT_MIN_ACTIVE_CHANNELS = 2
LOAD_BIAS_ENTER_THRESHOLD = 0.20
LOAD_BIAS_EXIT_THRESHOLD = 0.16
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
BASELINE_MIN_SAMPLES = 40
BASELINE_CALIBRATION_WINDOW_SAMPLES = 60
CALIBRATION_SAMPLE_INTERVAL_MS = 200
BASELINE_STABLE_GAP_MS = 1_500
# A low-sensitivity handmade insole can report about 0.066 total pressure on
# one foot during a valid bilateral stance. Keep this below the runtime risk
# load floor; multi-channel contact, balance, motion and stability checks still
# prevent unloaded residuals from becoming a baseline.
BASELINE_MIN_FOOT_PRESSURE = 0.04
# Pressure risks require meaningful loading. Temperature becomes independent
# of loading only after the empty reference and wearing baseline are locked.
RISK_MIN_TOTAL_PRESSURE = 0.08
# A single high residual can come from an unloaded or mechanically biased FSR
# (for example the observed right P3). Treat at least two trusted channels as
# the minimum evidence that either foot is actually contacting the insole.
PRESSURE_CONTACT_MIN_ACTIVE_CHANNELS = 2
PRESSURE_CONTACT_ACTIVE_FLOOR = 0.01
PRESSURE_RESIDUAL_MIN_SAMPLES = 10
PRESSURE_RESIDUAL_FLOOR = 0.02
PRESSURE_RESIDUAL_MAX_MAD = 0.008
BASELINE_ACTIVE_PRESSURE_FLOOR = 0.005
BASELINE_MIN_ACTIVE_CHANNELS = 3
BASELINE_CHANNEL_SATURATION = 0.995
BASELINE_CHANNEL_MAX_MAD = 0.08
BASELINE_BALANCED_BIAS_MAX = 0.50
BASELINE_MAX_TEMPERATURE_DELTA_C = 4.0
# MPU only gates personal-baseline sampling. Pressure and temperature risk
# detection remains active while walking. Missing MPU data fails open.
IMU_GRAVITY_MS2 = 9.80665
IMU_ACCEL_STATIONARY_TOLERANCE_MS2 = 3.0
# A shoe can rotate while the acceleration magnitude remains close to 1 g.
# Use a lower gyro threshold and compare consecutive vectors in risk_service.
IMU_GYRO_STATIONARY_THRESHOLD_DPS = 12.0
IMU_ACCEL_DELTA_MOVING_MS2 = 0.75
IMU_MOTION_HOLD_MS = 1_500
# Conservative gait observation from bilateral load transfer plus MPU motion.
# These values describe an engineering prototype, not clinical gait criteria.
GAIT_ANALYSIS_WINDOW_MS = 12_000
GAIT_MIN_WINDOW_MS = 4_000
GAIT_LOAD_SHIFT_THRESHOLD = 0.50
GAIT_MAX_ADAPTIVE_THRESHOLD = 1.00
GAIT_STEP_REFRACTORY_MS = 250
GAIT_MIN_STEP_CANDIDATES = 4
GAIT_MIN_MOVING_RATIO = 0.35
GAIT_MIN_CADENCE_SPM = 20.0
GAIT_MAX_CADENCE_SPM = 180.0
BASELINE_LOAD_BIAS_INLIER_TOLERANCE = 0.20
BASELINE_DISTRIBUTION_INLIER_TOLERANCE = 0.25
BASELINE_TEMPERATURE_INLIER_TOLERANCE_C = 1.5
BASELINE_MAD_SCALE = 1.4826
LOAD_RATIO_NOISE_MULTIPLIER = 3.0
FOREFOOT_NOISE_MULTIPLIER = 3.0
# A noisy first wearing session must not make the demonstration insensitive.
LOAD_RATIO_MAX_THRESHOLD = 0.55
FOREFOOT_MAX_THRESHOLD = 0.22
DEFAULT_PRESSURE_DISTRIBUTION = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)
FOREFOOT_RATIO_DELTA_THRESHOLD = 0.08
FOREFOOT_RATIO_EXIT_THRESHOLD = 0.05
REGIONAL_SHARE_DELTA_FOR_SEVERE = 0.50
REGIONAL_ASYMMETRY_FOR_SEVERE = 0.35
# A large raw same-region difference must always agree with the value shown
# in the App. The baseline-corrected threshold remains more sensitive.
TEMPERATURE_RAW_DELTA_C_THRESHOLD = 2.5
TEMPERATURE_RAW_DELTA_C_EXIT_THRESHOLD = 2.0
TEMPERATURE_DELTA_C_THRESHOLD = 2.5
TEMPERATURE_DELTA_C_EXIT_THRESHOLD = 2.0
# Baseline correction can reveal sensor-to-sensor changes, but it must not
# create a temperature alarm while both feet currently read almost the same.
TEMPERATURE_CORRECTED_RAW_SUPPORT_C = 1.0
# Real NTC/contact readings can briefly dip for one or two 5-Hz frames. Keep
# an established temperature episode alive across that short dropout, while a
# genuine recovery still clears promptly.
TEMPERATURE_DROPOUT_GRACE_MS = 1_200
ATTENTION_AFTER_MS = 5_000
WARNING_AFTER_MS = 10_000
PERSISTENT_AFTER_MS = 20_000
TEMPERATURE_ATTENTION_AFTER_MS = 8_000
TEMPERATURE_WARNING_AFTER_MS = 15_000
TEMPERATURE_PERSISTENT_AFTER_MS = 30_000
MOTOR_COMMAND_LEVEL = 3
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
