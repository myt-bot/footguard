from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.validate_protocol import (
    ProtocolValidationError,
    decode_sensor_frame,
    load_hex,
    main,
    validate_foot_frame,
)


EXAMPLES = ROOT / "protocol" / "examples"


def load_frame(side: str) -> dict:
    return json.loads((EXAMPLES / f"{side}_frame.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("side", ["left", "right"])
def test_standard_foot_frames_are_valid(side: str) -> None:
    validate_foot_frame(load_frame(side), f"{side}_frame.json")


def test_pressure_with_five_channels_is_rejected() -> None:
    frame = load_frame("left")
    frame["pressure"].pop()
    with pytest.raises(ProtocolValidationError, match="array length 6"):
        validate_foot_frame(frame)


def test_temperature_with_four_channels_is_rejected() -> None:
    frame = load_frame("left")
    frame["temperature"].append(30.0)
    with pytest.raises(ProtocolValidationError, match="array length 3"):
        validate_foot_frame(frame)


def test_uppercase_side_is_rejected() -> None:
    frame = load_frame("left")
    frame["side"] = "LEFT"
    with pytest.raises(ProtocolValidationError, match="expected left/right"):
        validate_foot_frame(frame)


def test_battery_above_100_is_rejected() -> None:
    frame = load_frame("left")
    frame["battery"] = 101
    with pytest.raises(ProtocolValidationError, match="integer 0..100"):
        validate_foot_frame(frame)


def test_unknown_frame_field_is_rejected() -> None:
    frame = load_frame("left")
    frame["unexpected"] = True
    with pytest.raises(ProtocolValidationError, match="field mismatch"):
        validate_foot_frame(frame)


def test_pressure_outside_normalized_range_is_rejected() -> None:
    frame = load_frame("left")
    frame["pressure"][0] = 1.01
    with pytest.raises(ProtocolValidationError, match="0.0..1.0"):
        validate_foot_frame(frame)


def test_reserved_quality_flag_is_rejected() -> None:
    frame = load_frame("left")
    frame["quality_flags"] = 1 << 15
    with pytest.raises(ProtocolValidationError, match="reserved bits"):
        validate_foot_frame(frame)


def test_unsynced_frame_requires_zero_timestamp_and_flag() -> None:
    frame = load_frame("left")
    frame["sync_id"] = 0
    with pytest.raises(ProtocolValidationError, match="timestamp_ms=0"):
        validate_foot_frame(frame)

    frame["timestamp_ms"] = 0
    with pytest.raises(ProtocolValidationError, match="TIME_UNSYNCED"):
        validate_foot_frame(frame)

    frame["quality_flags"] = 0x00000400
    validate_foot_frame(frame)


@pytest.mark.parametrize("side", ["left", "right"])
def test_standard_58_byte_sensor_vectors_are_valid(side: str) -> None:
    raw = load_hex(EXAMPLES / f"sensor_frame_{side}_v1.hex")
    decoded = decode_sensor_frame(raw, expected_side=side)
    assert len(raw) == 58
    assert decoded["side"] == side


def test_sensor_frame_wrong_length_is_rejected() -> None:
    raw = load_hex(EXAMPLES / "sensor_frame_left_v1.hex")
    with pytest.raises(ProtocolValidationError, match="expected 58 bytes"):
        decode_sensor_frame(raw[:-1], expected_side="left")


def test_sensor_frame_crc_corruption_is_rejected() -> None:
    raw = bytearray(load_hex(EXAMPLES / "sensor_frame_left_v1.hex"))
    raw[25] ^= 0x01
    with pytest.raises(ProtocolValidationError, match="crc16"):
        decode_sensor_frame(bytes(raw), expected_side="left")


def test_sensor_frame_side_mismatch_is_rejected() -> None:
    raw = load_hex(EXAMPLES / "sensor_frame_left_v1.hex")
    with pytest.raises(ProtocolValidationError, match="expected right"):
        decode_sensor_frame(raw, expected_side="right")


def test_full_validator_returns_success() -> None:
    assert main() == 0
