"""Validate FootGuard protocol v1 schemas, examples and BLE test vectors."""

from __future__ import annotations

import json
import math
import re
import struct
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_DIR = ROOT / "protocol"
EXAMPLES_DIR = PROTOCOL_DIR / "examples"

PROTOCOL_VERSION = 1
SENSOR_LAYOUT_VERSION = "layout_6p4t_v1"
FRAME_FIELDS = {
    "protocol_version",
    "sensor_layout_version",
    "device_id",
    "side",
    "sync_id",
    "packet_seq",
    "timestamp_ms",
    "pressure",
    "temperature",
    "imu",
    "battery",
    "quality_flags",
    "source",
}
IMU_FIELDS = {"ax", "ay", "az", "gx", "gy", "gz"}
DEVICE_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,16}$")
UINT32_MAX = 0xFFFFFFFF
RESERVED_QUALITY_MASK = 0xFFFF0000
TIME_UNSYNCED = 0x00000800


class ProtocolValidationError(ValueError):
    """Raised when protocol data violates the v1 baseline."""


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ProtocolValidationError(f"{path.name}: root must be an object")
    return data


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _require_uint32(value: Any, field: str, label: str) -> None:
    if not _is_integer(value) or not 0 <= value <= UINT32_MAX:
        raise ProtocolValidationError(
            f"{label}.{field}: expected uint32, got {value!r}"
        )


def _require_numeric_array(
    value: Any,
    *,
    field: str,
    length: int,
    minimum: float,
    maximum: float,
    label: str,
) -> None:
    if not isinstance(value, list) or len(value) != length:
        actual = len(value) if isinstance(value, list) else type(value).__name__
        raise ProtocolValidationError(
            f"{label}.{field}: expected array length {length}, got {actual}"
        )
    for index, item in enumerate(value):
        if not _is_number(item) or not minimum <= float(item) <= maximum:
            raise ProtocolValidationError(
                f"{label}.{field}[{index}]: expected {minimum}..{maximum}, "
                f"got {item!r}"
            )


def validate_foot_frame(frame: dict[str, Any], label: str = "frame") -> None:
    """Validate one unified App/backend foot frame."""

    actual_fields = set(frame)
    if actual_fields != FRAME_FIELDS:
        missing = sorted(FRAME_FIELDS - actual_fields)
        extra = sorted(actual_fields - FRAME_FIELDS)
        raise ProtocolValidationError(
            f"{label}: field mismatch; missing={missing}, extra={extra}"
        )

    if frame["protocol_version"] != PROTOCOL_VERSION or not _is_integer(
        frame["protocol_version"]
    ):
        raise ProtocolValidationError(
            f"{label}.protocol_version: expected integer 1"
        )
    if frame["sensor_layout_version"] != SENSOR_LAYOUT_VERSION:
        raise ProtocolValidationError(
            f"{label}.sensor_layout_version: expected {SENSOR_LAYOUT_VERSION}"
        )
    if not isinstance(frame["device_id"], str) or not DEVICE_ID_PATTERN.fullmatch(
        frame["device_id"]
    ):
        raise ProtocolValidationError(
            f"{label}.device_id: expected 1..16 ASCII letters, digits, _ or -"
        )
    if frame["side"] not in {"left", "right"}:
        raise ProtocolValidationError(
            f"{label}.side: expected left/right, got {frame['side']!r}"
        )
    if frame["source"] not in {"mock", "csv_replay", "ble"}:
        raise ProtocolValidationError(
            f"{label}.source: unsupported value {frame['source']!r}"
        )

    _require_uint32(frame["sync_id"], "sync_id", label)
    _require_uint32(frame["packet_seq"], "packet_seq", label)
    _require_uint32(frame["quality_flags"], "quality_flags", label)
    if frame["quality_flags"] & RESERVED_QUALITY_MASK:
        raise ProtocolValidationError(f"{label}.quality_flags: reserved bits must be 0")

    if not _is_integer(frame["timestamp_ms"]) or frame["timestamp_ms"] < 0:
        raise ProtocolValidationError(
            f"{label}.timestamp_ms: expected non-negative integer"
        )
    if frame["sync_id"] == 0:
        if frame["timestamp_ms"] != 0:
            raise ProtocolValidationError(
                f"{label}: sync_id=0 requires timestamp_ms=0"
            )
        if not frame["quality_flags"] & TIME_UNSYNCED:
            raise ProtocolValidationError(
                f"{label}: sync_id=0 requires TIME_UNSYNCED quality flag"
            )

    _require_numeric_array(
        frame["pressure"],
        field="pressure",
        length=6,
        minimum=0.0,
        maximum=1.0,
        label=label,
    )
    _require_numeric_array(
        frame["temperature"],
        field="temperature",
        length=4,
        minimum=-40.0,
        maximum=125.0,
        label=label,
    )

    imu = frame["imu"]
    if not isinstance(imu, dict) or set(imu) != IMU_FIELDS:
        missing = sorted(IMU_FIELDS - set(imu)) if isinstance(imu, dict) else []
        extra = sorted(set(imu) - IMU_FIELDS) if isinstance(imu, dict) else []
        raise ProtocolValidationError(
            f"{label}.imu: expected exactly six fields; "
            f"missing={missing}, extra={extra}"
        )
    for field in sorted(IMU_FIELDS):
        if not _is_number(imu[field]):
            raise ProtocolValidationError(
                f"{label}.imu.{field}: expected finite number"
            )

    if not _is_integer(frame["battery"]) or not 0 <= frame["battery"] <= 100:
        raise ProtocolValidationError(
            f"{label}.battery: expected integer 0..100, got {frame['battery']!r}"
        )


def load_schema(path: Path) -> dict[str, Any]:
    schema = load_json(path)
    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        raise ProtocolValidationError(f"{path.name}: invalid schema: {exc.message}")
    return schema


def validate_against_schema(
    instance: dict[str, Any], schema: dict[str, Any], label: str
) -> None:
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if errors:
        error = errors[0]
        path = ".".join(str(part) for part in error.path)
        suffix = f".{path}" if path else ""
        raise ProtocolValidationError(f"{label}{suffix}: {error.message}")


def compact_json_size(instance: dict[str, Any]) -> int:
    return len(
        json.dumps(instance, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    )


def validate_ble_json_size(instance: dict[str, Any], label: str) -> None:
    size = compact_json_size(instance)
    if size > 244:
        raise ProtocolValidationError(
            f"{label}: compact UTF-8 JSON is {size} bytes, maximum is 244"
        )


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def load_hex(path: Path) -> bytes:
    try:
        return bytes.fromhex(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise ProtocolValidationError(f"{path.name}: invalid hex: {exc}") from exc


def decode_sensor_frame(raw: bytes, expected_side: str | None = None) -> dict[str, Any]:
    if len(raw) != 60:
        raise ProtocolValidationError(
            f"SensorData: expected 60 bytes, got {len(raw)}"
        )
    if raw[0:2] != b"FG":
        raise ProtocolValidationError("SensorData.magic: expected bytes 46 47")
    if raw[2] != PROTOCOL_VERSION:
        raise ProtocolValidationError(
            f"SensorData.protocol_version: unsupported {raw[2]}"
        )
    if raw[3] != 2:
        raise ProtocolValidationError(f"SensorData.layout_id: unsupported {raw[3]}")
    if raw[4] not in (0, 1):
        raise ProtocolValidationError(f"SensorData.side: invalid code {raw[4]}")

    side = "left" if raw[4] == 0 else "right"
    if expected_side is not None and side != expected_side:
        raise ProtocolValidationError(
            f"SensorData.side: expected {expected_side}, decoded {side}"
        )

    stored_crc = struct.unpack_from("<H", raw, 58)[0]
    calculated_crc = crc16_ccitt_false(raw[:58])
    if stored_crc != calculated_crc:
        raise ProtocolValidationError(
            f"SensorData.crc16: stored 0x{stored_crc:04X}, "
            f"calculated 0x{calculated_crc:04X}"
        )

    quality_flags = struct.unpack_from("<I", raw, 5)[0]
    if quality_flags & RESERVED_QUALITY_MASK:
        raise ProtocolValidationError("SensorData.quality_flags: reserved bits must be 0")
    battery = raw[57]
    if battery > 100:
        raise ProtocolValidationError(
            f"SensorData.battery: expected 0..100, got {battery}"
        )

    return {
        "protocol_version": raw[2],
        "layout_id": raw[3],
        "side": side,
        "quality_flags": quality_flags,
        "sync_id": struct.unpack_from("<I", raw, 9)[0],
        "packet_seq": struct.unpack_from("<I", raw, 13)[0],
        "timestamp_ms": struct.unpack_from("<Q", raw, 17)[0],
        "pressure": [value / 10000.0 for value in struct.unpack_from("<6H", raw, 25)],
        "temperature": [value / 100.0 for value in struct.unpack_from("<4h", raw, 37)],
        "acceleration": [
            value * 9.80665 / 1000.0
            for value in struct.unpack_from("<3h", raw, 45)
        ],
        "gyroscope": [value / 10.0 for value in struct.unpack_from("<3h", raw, 51)],
        "battery": battery,
        "crc16": stored_crc,
    }


def _assert_close_list(
    actual: list[float], expected: list[float], tolerance: float, label: str
) -> None:
    if len(actual) != len(expected):
        raise ProtocolValidationError(f"{label}: length mismatch")
    for index, (left, right) in enumerate(zip(actual, expected, strict=True)):
        if abs(left - right) > tolerance:
            raise ProtocolValidationError(
                f"{label}[{index}]: decoded {left}, expected {right}"
            )


def validate_sensor_vector(side: str) -> None:
    raw = load_hex(EXAMPLES_DIR / f"sensor_frame_{side}_v1.hex")
    decoded = decode_sensor_frame(raw, expected_side=side)
    expected = load_json(EXAMPLES_DIR / f"{side}_frame.json")

    for field in ("protocol_version", "quality_flags", "sync_id", "packet_seq", "timestamp_ms", "battery"):
        if decoded[field] != expected[field]:
            raise ProtocolValidationError(
                f"{side} vector {field}: decoded {decoded[field]!r}, "
                f"expected {expected[field]!r}"
            )
    _assert_close_list(decoded["pressure"], expected["pressure"], 0.00005, f"{side}.pressure")
    _assert_close_list(decoded["temperature"], expected["temperature"], 0.005, f"{side}.temperature")
    _assert_close_list(
        decoded["acceleration"],
        [expected["imu"][field] for field in ("ax", "ay", "az")],
        0.005,
        f"{side}.acceleration",
    )
    _assert_close_list(
        decoded["gyroscope"],
        [expected["imu"][field] for field in ("gx", "gy", "gz")],
        0.05,
        f"{side}.gyroscope",
    )


def validate_time_sync_vector() -> None:
    raw = load_hex(EXAMPLES_DIR / "time_sync_v1.hex")
    if len(raw) != 12:
        raise ProtocolValidationError(
            f"TimeSync: expected 12 bytes, got {len(raw)}"
        )
    sync_id, unix_time_ms = struct.unpack("<IQ", raw)
    if (sync_id, unix_time_ms) != (1, 1760000000000):
        raise ProtocolValidationError(
            f"TimeSync: decoded {(sync_id, unix_time_ms)!r}"
        )


def run_validation() -> None:
    if crc16_ccitt_false(b"123456789") != 0x29B1:
        raise ProtocolValidationError("CRC implementation failed standard check value")

    for side in ("left", "right"):
        validate_foot_frame(
            load_json(EXAMPLES_DIR / f"{side}_frame.json"), f"{side}_frame.json"
        )

    schema_groups = (
        ("command_schema_v1.json", "command_*.json"),
        ("ack_schema_v1.json", "ack_*.json"),
        ("device_status_schema_v1.json", "device_status_*.json"),
    )
    for schema_name, pattern in schema_groups:
        schema = load_schema(PROTOCOL_DIR / schema_name)
        paths = sorted(EXAMPLES_DIR.glob(pattern))
        if not paths:
            raise ProtocolValidationError(f"{pattern}: no examples found")
        for path in paths:
            instance = load_json(path)
            validate_against_schema(instance, schema, path.name)
            validate_ble_json_size(instance, path.name)

    validate_sensor_vector("left")
    validate_sensor_vector("right")
    validate_time_sync_vector()


def main() -> int:
    try:
        run_validation()
    except (OSError, json.JSONDecodeError, ProtocolValidationError) as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print("[OK] FootGuard protocol v1 schemas, examples and BLE vectors are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
