from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "backend" / "data"
DEFAULT_DATABASE_URL = f"sqlite:///{(DATA_DIR / 'footguard.db').as_posix()}"

# Competition prototype thresholds. These are engineering defaults, not medical standards.
PAIRING_WINDOW_MS = 100
CONTINUITY_GAP_MS = 1_000
PRESSURE_INVALID_MASK = 0x0000003F
TEMPERATURE_INVALID_MASK = 0x000003C0
TIME_UNSYNCED_MASK = 0x00000800
CALIBRATION_INVALID_MASK = 0x00002000
SENSOR_STUCK_MASK = 0x00004000
PAIRING_BLOCK_FLAGS = (
    PRESSURE_INVALID_MASK
    | TEMPERATURE_INVALID_MASK
    | TIME_UNSYNCED_MASK
    | CALIBRATION_INVALID_MASK
    | SENSOR_STUCK_MASK
)
LOAD_BIAS_ENTER_THRESHOLD = 0.25
LOAD_BIAS_EXIT_THRESHOLD = 0.15
# Pressure decisions use dimensionless ratios and change from a personal
# baseline. Raw sensor values are never compared directly with body-weight
# dependent alarm thresholds.
BASELINE_MIN_SAMPLES = 10
BASELINE_BALANCED_BIAS_MAX = 0.12
DEFAULT_PRESSURE_DISTRIBUTION = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)
FOREFOOT_RATIO_DELTA_THRESHOLD = 0.12
REGIONAL_SHARE_DELTA_FOR_SEVERE = 0.50
REGIONAL_ASYMMETRY_FOR_SEVERE = 0.35
TEMPERATURE_DELTA_C_THRESHOLD = 2.0
ATTENTION_AFTER_MS = 3_000
WARNING_AFTER_MS = 6_000
PERSISTENT_AFTER_MS = 10_000
MOTOR_COMMAND_LEVEL = 2
MOTOR_PATTERN = "double"
MOTOR_DURATION_MS = 800
# Human-facing competition demo: leave enough time for the App polling cycle
# and for the user to press the simulated execution button.
MOTOR_COMMAND_TTL_MS = 30_000
RECOVERY_EFFECTIVE_RATIO = 0.50
RECOVERY_PARTIAL_RATIO = 0.20
RECOVERY_OBSERVATION_MS = 15_000


def database_url() -> str:
    return os.getenv("FOOTGUARD_DATABASE_URL", DEFAULT_DATABASE_URL)
