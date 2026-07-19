from __future__ import annotations

import csv
import hashlib
import sys
from collections import defaultdict
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.generate_mock_data import (  # noqa: E402
    CSV_COLUMNS,
    DEFAULT_DURATION_SECONDS,
    DEFAULT_FREQUENCY_HZ,
    DEFAULT_SEED,
    SCENARIOS,
    generate_all,
)


SAMPLE_DATA = ROOT / "sample_data"
PRESSURE_COLUMNS = tuple(f"p{index}" for index in range(1, 7))
TEMPERATURE_COLUMNS = tuple(f"t{index}" for index in range(1, 4))
IMU_COLUMNS = ("ax", "ay", "az", "gx", "gy", "gz")


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def rows_by_side(rows: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["side"]].append(row)
    return grouped


def paired_biases(rows: list[dict[str, str]]) -> list[tuple[int, float]]:
    pairs: dict[tuple[int, int], dict[str, dict[str, str]]] = defaultdict(dict)
    for row in rows:
        key = (int(row["sync_id"]), int(row["packet_seq"]))
        pairs[key][row["side"]] = row

    values: list[tuple[int, float]] = []
    for (_, packet_seq), pair in sorted(pairs.items()):
        if set(pair) != {"left", "right"}:
            continue
        left_total = sum(float(pair["left"][column]) for column in PRESSURE_COLUMNS)
        right_total = sum(float(pair["right"][column]) for column in PRESSURE_COLUMNS)
        total = left_total + right_total
        bias = (left_total - right_total) / max(total, 1e-9)
        values.append((packet_seq, bias))
    return values


def longest_threshold_run(
    biases: list[tuple[int, float]], predicate
) -> int:
    longest = 0
    current = 0
    previous_seq: int | None = None
    for packet_seq, bias in biases:
        if predicate(bias) and (previous_seq is None or packet_seq == previous_seq + 1):
            current += 1
        elif predicate(bias):
            current = 1
        else:
            current = 0
        longest = max(longest, current)
        previous_seq = packet_seq
    return longest


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_all_sample_files_exist_and_have_rows(scenario: str) -> None:
    path = SAMPLE_DATA / f"{scenario}.csv"
    assert path.is_file()
    rows = read_rows(path)
    assert rows
    assert tuple(rows[0]) == CSV_COLUMNS


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_protocol_fields_and_ranges(scenario: str) -> None:
    rows = read_rows(SAMPLE_DATA / f"{scenario}.csv")
    for row in rows:
        assert row["protocol_version"] == "1"
        assert row["sensor_layout_version"] == "layout_6p3t_v1"
        assert row["side"] in {"left", "right"}
        assert row["source"] == "csv_replay"
        assert 0 <= int(row["battery"]) <= 100
        assert int(row["quality_flags"]) == 0
        assert all(0.0 <= float(row[column]) <= 1.0 for column in PRESSURE_COLUMNS)
        assert all(-40.0 <= float(row[column]) <= 125.0 for column in TEMPERATURE_COLUMNS)
        assert all(row[column] != "" for column in IMU_COLUMNS)


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_packet_sequences_increase_independently(scenario: str) -> None:
    grouped = rows_by_side(read_rows(SAMPLE_DATA / f"{scenario}.csv"))
    for side, rows in grouped.items():
        sequence = [int(row["packet_seq"]) for row in rows]
        assert sequence == list(range(len(sequence))), side


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_left_right_pairs_share_sync_id_and_are_within_50_ms(scenario: str) -> None:
    rows = read_rows(SAMPLE_DATA / f"{scenario}.csv")
    pairs: dict[int, dict[str, dict[str, str]]] = defaultdict(dict)
    for row in rows:
        pairs[int(row["packet_seq"])][row["side"]] = row
    for pair in pairs.values():
        if set(pair) != {"left", "right"}:
            continue
        assert pair["left"]["sync_id"] == pair["right"]["sync_id"]
        delta = abs(
            int(pair["left"]["timestamp_ms"])
            - int(pair["right"]["timestamp_ms"])
        )
        assert delta <= 50


def test_standard_scenarios_are_30_seconds_at_5_hz() -> None:
    expected_per_side = DEFAULT_DURATION_SECONDS * DEFAULT_FREQUENCY_HZ
    for scenario in SCENARIOS:
        grouped = rows_by_side(read_rows(SAMPLE_DATA / f"{scenario}.csv"))
        assert len(grouped["left"]) == expected_per_side
        expected_right = expected_per_side // 2 if scenario == "right_disconnect" else expected_per_side
        assert len(grouped["right"]) == expected_right


def test_normal_stand_does_not_trigger_persistent_bias() -> None:
    biases = paired_biases(read_rows(SAMPLE_DATA / "normal_stand.csv"))
    run = longest_threshold_run(biases, lambda value: abs(value) > 0.25)
    assert run < 3 * DEFAULT_FREQUENCY_HZ


def test_normal_walk_only_has_short_alternating_bias() -> None:
    biases = paired_biases(read_rows(SAMPLE_DATA / "normal_walk.csv"))
    left_run = longest_threshold_run(biases, lambda value: value > 0.25)
    right_run = longest_threshold_run(biases, lambda value: value < -0.25)
    assert left_run < 3 * DEFAULT_FREQUENCY_HZ
    assert right_run < 3 * DEFAULT_FREQUENCY_HZ
    assert any(value > 0.25 for _, value in biases)
    assert any(value < -0.25 for _, value in biases)


def test_left_load_bias_is_sustained() -> None:
    biases = paired_biases(read_rows(SAMPLE_DATA / "left_load_bias.csv"))
    run = longest_threshold_run(biases, lambda value: value > 0.25)
    assert run >= 10 * DEFAULT_FREQUENCY_HZ


def test_right_load_bias_is_sustained() -> None:
    biases = paired_biases(read_rows(SAMPLE_DATA / "right_load_bias.csv"))
    run = longest_threshold_run(biases, lambda value: value < -0.25)
    assert run >= 10 * DEFAULT_FREQUENCY_HZ


def test_left_forefoot_channels_are_higher_than_heel() -> None:
    rows = rows_by_side(read_rows(SAMPLE_DATA / "left_forefoot_high.csv"))["left"]
    forefoot = sum(sum(float(row[f"p{index}"]) for index in (1, 2, 3)) for row in rows) / len(rows)
    heel = sum(sum(float(row[f"p{index}"]) for index in (5, 6)) for row in rows) / len(rows)
    assert forefoot / 3 > heel / 2 + 0.30


def test_right_disconnect_has_unpaired_left_tail() -> None:
    grouped = rows_by_side(read_rows(SAMPLE_DATA / "right_disconnect.csv"))
    assert len(grouped["left"]) > len(grouped["right"])
    assert int(grouped["left"][-1]["timestamp_ms"]) - int(grouped["right"][-1]["timestamp_ms"]) > 10000


def test_intervention_recovery_moves_from_bias_to_balance() -> None:
    biases = [value for _, value in paired_biases(read_rows(SAMPLE_DATA / "intervention_recovery.csv"))]
    window = 10 * DEFAULT_FREQUENCY_HZ
    early = sum(abs(value) for value in biases[:window]) / window
    late = sum(abs(value) for value in biases[-window:]) / window
    assert early > 0.25
    assert late < 0.10


def test_generation_is_reproducible(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    generate_all(first, seed=DEFAULT_SEED)
    generate_all(second, seed=DEFAULT_SEED)
    for scenario in SCENARIOS:
        first_hash = hashlib.sha256((first / f"{scenario}.csv").read_bytes()).digest()
        second_hash = hashlib.sha256((second / f"{scenario}.csv").read_bytes()).digest()
        assert first_hash == second_hash
