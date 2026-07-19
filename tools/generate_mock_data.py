"""Generate reproducible dual-foot CSV data for FootGuard protocol v1."""

from __future__ import annotations

import argparse
import csv
import math
import random
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / "sample_data"

PROTOCOL_VERSION = 1
SENSOR_LAYOUT_VERSION = "layout_6p4t_v1"
SOURCE = "csv_replay"
DEFAULT_SEED = 20260718
DEFAULT_FREQUENCY_HZ = 5
DEFAULT_DURATION_SECONDS = 30
RIGHT_TIMESTAMP_OFFSET_MS = 20

SCENARIOS = (
    "normal_stand",
    "normal_walk",
    "left_load_bias",
    "right_load_bias",
    "left_forefoot_high",
    "left_temperature_rise",
    "right_disconnect",
    "intervention_recovery",
)

CSV_COLUMNS = (
    "protocol_version",
    "sensor_layout_version",
    "device_id",
    "side",
    "sync_id",
    "packet_seq",
    "timestamp_ms",
    "p1",
    "p2",
    "p3",
    "p4",
    "p5",
    "p6",
    "t1",
    "t2",
    "t3",
    "t4",
    "ax",
    "ay",
    "az",
    "gx",
    "gy",
    "gz",
    "battery",
    "quality_flags",
    "source",
)

STAND_WEIGHTS = (0.16, 0.17, 0.18, 0.14, 0.18, 0.17)
FOREFOOT_WEIGHTS = (0.23, 0.22, 0.24, 0.20, 0.06, 0.05)


def clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


def pressure_channels(
    total: float,
    weights: tuple[float, ...],
    rng: random.Random,
    noise: float = 0.008,
) -> list[float]:
    values = [clamp(total * weight + rng.uniform(-noise, noise), 0.0, 1.0) for weight in weights]
    return [round(value, 4) for value in values]


def temperature_channels(
    scenario: str, side: str, time_s: float, rng: random.Random
) -> list[float]:
    side_offset = 0.05 if side == "left" else -0.05
    drift = 0.08 * math.sin(2.0 * math.pi * time_s / 30.0)
    # T1=forefoot lateral, T2=forefoot medial, T3=heel centre,
    # T4=midfoot medial.
    bases = (30.7, 30.8, 30.4, 30.6)
    hotspot = (0.0, 2.8, 0.0, 0.0) if scenario == "left_temperature_rise" and side == "left" else (0.0,) * 4
    return [
        round(base + hotspot[index] + side_offset + drift + rng.uniform(-0.03, 0.03), 2)
        for index, base in enumerate(bases)
    ]


def imu_channels(
    scenario: str, side: str, time_s: float, rng: random.Random
) -> tuple[float, float, float, float, float, float]:
    if scenario == "normal_walk":
        phase = 2.0 * math.pi * time_s + (0.0 if side == "left" else math.pi)
        ax = 0.55 * math.sin(phase) + rng.uniform(-0.03, 0.03)
        ay = 0.20 * math.cos(phase) + rng.uniform(-0.02, 0.02)
        az = 9.80665 + 1.10 * abs(math.sin(phase)) + rng.uniform(-0.04, 0.04)
        gx = 18.0 * math.sin(phase) + rng.uniform(-0.3, 0.3)
        gy = 7.0 * math.cos(phase) + rng.uniform(-0.2, 0.2)
        gz = 3.0 * math.sin(phase / 2.0) + rng.uniform(-0.1, 0.1)
    else:
        ax = rng.uniform(-0.03, 0.03)
        ay = rng.uniform(-0.03, 0.03)
        az = 9.80665 + rng.uniform(-0.04, 0.04)
        gx = rng.uniform(-0.3, 0.3)
        gy = rng.uniform(-0.3, 0.3)
        gz = rng.uniform(-0.2, 0.2)
    return tuple(round(value, 4) for value in (ax, ay, az, gx, gy, gz))


def scenario_loads(
    scenario: str, time_s: float, duration_seconds: int
) -> tuple[float, float, tuple[float, ...], tuple[float, ...]]:
    left_weights = STAND_WEIGHTS
    right_weights = STAND_WEIGHTS

    if scenario in {"normal_stand", "right_disconnect"}:
        return 1.80, 1.75, left_weights, right_weights
    if scenario == "normal_walk":
        phase = 2.0 * math.pi * time_s
        left_total = 1.25 + 1.05 * math.sin(phase)
        right_total = 1.25 - 1.05 * math.sin(phase)
        return max(0.15, left_total), max(0.15, right_total), left_weights, right_weights
    if scenario == "left_load_bias":
        return 2.80, 1.10, left_weights, right_weights
    if scenario == "right_load_bias":
        return 1.10, 2.80, left_weights, right_weights
    if scenario == "left_forefoot_high":
        return 1.80, 1.75, FOREFOOT_WEIGHTS, right_weights
    if scenario == "left_temperature_rise":
        return 1.80, 1.75, left_weights, right_weights
    if scenario == "intervention_recovery":
        bias_end = duration_seconds * 0.40
        recovery_end = duration_seconds * 0.60
        if time_s < bias_end:
            return 2.80, 1.10, left_weights, right_weights
        if time_s < recovery_end:
            progress = (time_s - bias_end) / (recovery_end - bias_end)
            left_total = 2.80 + (1.80 - 2.80) * progress
            right_total = 1.10 + (1.75 - 1.10) * progress
            return left_total, right_total, left_weights, right_weights
        return 1.80, 1.75, left_weights, right_weights
    raise ValueError(f"unsupported scenario: {scenario}")


def build_row(
    *,
    scenario: str,
    side: str,
    sync_id: int,
    packet_seq: int,
    timestamp_ms: int,
    time_s: float,
    total_load: float,
    weights: tuple[float, ...],
    rng: random.Random,
) -> dict[str, object]:
    pressure = pressure_channels(total_load, weights, rng)
    temperature = temperature_channels(scenario, side, time_s, rng)
    imu = imu_channels(scenario, side, time_s, rng)
    row: dict[str, object] = {
        "protocol_version": PROTOCOL_VERSION,
        "sensor_layout_version": SENSOR_LAYOUT_VERSION,
        "device_id": "foot_left_001" if side == "left" else "foot_right_001",
        "side": side,
        "sync_id": sync_id,
        "packet_seq": packet_seq,
        "timestamp_ms": timestamp_ms,
        "battery": 95 if side == "left" else 93,
        "quality_flags": 0,
        "source": SOURCE,
    }
    row.update({f"p{index + 1}": pressure[index] for index in range(6)})
    row.update({f"t{index + 1}": temperature[index] for index in range(4)})
    row.update(
        {
            name: value
            for name, value in zip(("ax", "ay", "az", "gx", "gy", "gz"), imu, strict=True)
        }
    )
    return row


def generate_scenario_rows(
    scenario: str,
    *,
    scenario_index: int,
    seed: int,
    frequency_hz: int,
    duration_seconds: int,
) -> list[dict[str, object]]:
    if scenario not in SCENARIOS:
        raise ValueError(f"unsupported scenario: {scenario}")
    if frequency_hz <= 0 or duration_seconds <= 0:
        raise ValueError("frequency_hz and duration_seconds must be positive")

    rng = random.Random(seed + scenario_index * 1009)
    frame_count = frequency_hz * duration_seconds
    interval_ms = round(1000 / frequency_hz)
    base_timestamp_ms = 1760000000000 + scenario_index * 100000
    sync_id = 1001 + scenario_index
    rows: list[dict[str, object]] = []

    for packet_seq in range(frame_count):
        time_s = packet_seq / frequency_hz
        left_total, right_total, left_weights, right_weights = scenario_loads(
            scenario, time_s, duration_seconds
        )
        left_timestamp = base_timestamp_ms + packet_seq * interval_ms
        rows.append(
            build_row(
                scenario=scenario,
                side="left",
                sync_id=sync_id,
                packet_seq=packet_seq,
                timestamp_ms=left_timestamp,
                time_s=time_s,
                total_load=left_total,
                weights=left_weights,
                rng=rng,
            )
        )

        right_connected = not (
            scenario == "right_disconnect" and packet_seq >= frame_count // 2
        )
        if right_connected:
            rows.append(
                build_row(
                    scenario=scenario,
                    side="right",
                    sync_id=sync_id,
                    packet_seq=packet_seq,
                    timestamp_ms=left_timestamp + RIGHT_TIMESTAMP_OFFSET_MS,
                    time_s=time_s,
                    total_load=right_total,
                    weights=right_weights,
                    rng=rng,
                )
            )
    return rows


def write_csv(path: Path, rows: Iterable[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS, extrasaction="raise")
        writer.writeheader()
        writer.writerows(rows)


def generate_all(
    output_dir: Path = DEFAULT_OUTPUT_DIR,
    *,
    seed: int = DEFAULT_SEED,
    frequency_hz: int = DEFAULT_FREQUENCY_HZ,
    duration_seconds: int = DEFAULT_DURATION_SECONDS,
) -> dict[str, Path]:
    generated: dict[str, Path] = {}
    for index, scenario in enumerate(SCENARIOS):
        rows = generate_scenario_rows(
            scenario,
            scenario_index=index,
            seed=seed,
            frequency_hz=frequency_hz,
            duration_seconds=duration_seconds,
        )
        path = output_dir / f"{scenario}.csv"
        write_csv(path, rows)
        generated[scenario] = path
    return generated


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--frequency-hz", type=int, default=DEFAULT_FREQUENCY_HZ)
    parser.add_argument("--duration-seconds", type=int, default=DEFAULT_DURATION_SECONDS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    generated = generate_all(
        args.output_dir,
        seed=args.seed,
        frequency_hz=args.frequency_hz,
        duration_seconds=args.duration_seconds,
    )
    print(
        f"[OK] generated {len(generated)} scenarios at "
        f"{args.frequency_hz} Hz for {args.duration_seconds} seconds"
    )
    for scenario, path in generated.items():
        print(f"  {scenario}: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
