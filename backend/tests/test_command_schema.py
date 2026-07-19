from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator


ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / "protocol"
EXAMPLES = PROTOCOL / "examples"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def validator(schema_name: str) -> Draft202012Validator:
    schema = load_json(PROTOCOL / schema_name)
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def assert_invalid(instance: dict, schema_validator: Draft202012Validator) -> None:
    assert list(schema_validator.iter_errors(instance)), "expected invalid instance"


@pytest.mark.parametrize("name", ["command_double.json", "command_off.json"])
def test_standard_commands_are_valid(name: str) -> None:
    validator("command_schema_v1.json").validate(load_json(EXAMPLES / name))


def test_command_target_none_is_rejected() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    instance["target"] = "none"
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_command_duration_above_schema_range_is_rejected() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    instance["duration_ms"] = 5001
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_command_without_id_is_rejected() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    del instance["command_id"]
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_command_with_unknown_field_is_rejected() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    instance["unexpected"] = True
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_off_command_requires_zero_duration() -> None:
    instance = load_json(EXAMPLES / "command_off.json")
    instance["duration_ms"] = 1
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_double_command_enforces_pattern_specific_duration() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    instance["duration_ms"] = 100
    assert_invalid(instance, validator("command_schema_v1.json"))


def test_unsupported_command_protocol_version_is_rejected() -> None:
    instance = load_json(EXAMPLES / "command_double.json")
    instance["protocol_version"] = 2
    assert_invalid(instance, validator("command_schema_v1.json"))


@pytest.mark.parametrize(
    "name",
    [
        "ack_executed.json",
        "ack_rejected.json",
        "ack_expired.json",
        "ack_failed.json",
    ],
)
def test_standard_ack_examples_are_valid(name: str) -> None:
    validator("ack_schema_v1.json").validate(load_json(EXAMPLES / name))


def test_executed_ack_requires_executed_at() -> None:
    instance = load_json(EXAMPLES / "ack_executed.json")
    del instance["executed_at_ms"]
    assert_invalid(instance, validator("ack_schema_v1.json"))


def test_rejected_ack_cannot_report_none_error() -> None:
    instance = load_json(EXAMPLES / "ack_rejected.json")
    instance["error_code"] = "none"
    assert_invalid(instance, validator("ack_schema_v1.json"))


@pytest.mark.parametrize(
    "name", ["device_status_left.json", "device_status_right.json"]
)
def test_standard_device_status_examples_are_valid(name: str) -> None:
    validator("device_status_schema_v1.json").validate(load_json(EXAMPLES / name))


def test_unsynced_device_status_requires_sync_id_zero() -> None:
    instance = load_json(EXAMPLES / "device_status_left.json")
    instance["time_synced"] = False
    instance["sync_id"] = 1
    assert_invalid(instance, validator("device_status_schema_v1.json"))


def test_device_status_unknown_state_is_rejected() -> None:
    instance = load_json(EXAMPLES / "device_status_left.json")
    instance["state"] = "connected"
    assert_invalid(instance, validator("device_status_schema_v1.json"))


@pytest.mark.parametrize(
    "pattern",
    ["command_*.json", "ack_*.json", "device_status_*.json"],
)
def test_ble_json_examples_fit_mtu_247(pattern: str) -> None:
    for path in EXAMPLES.glob(pattern):
        compact = json.dumps(
            load_json(path), separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        assert len(compact) <= 244, f"{path.name} is {len(compact)} bytes"
