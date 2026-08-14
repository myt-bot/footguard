from __future__ import annotations

import argparse
import csv
import json
import sqlite3
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path


LOCAL_TIMEZONE = timezone(timedelta(hours=8))
SESSION_DATE = date(2026, 8, 14)


@dataclass(frozen=True)
class Interval:
    label: str
    start: str
    end: str
    confidence: str = "high"
    note: str = ""

    def bounds_ms(self) -> tuple[int, int]:
        start = datetime.combine(
            SESSION_DATE, time.fromisoformat(self.start), LOCAL_TIMEZONE
        )
        end = datetime.combine(
            SESSION_DATE, time.fromisoformat(self.end), LOCAL_TIMEZONE
        )
        return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


SESSIONS = {
    "person_a_session_01": {
        "window": ("21:08:00", "21:18:21"),
        "notes": [
            "Personal baseline did not lock; use the normal interval only as a session reference.",
            "Frames after 21:16:25 are sparse and must not set production thresholds.",
            "21:10:05-21:11:14 is unloaded and excluded.",
        ],
        "intervals": [
            Interval("exclude_prebaseline", "21:08:00", "21:11:25", "exclude"),
            Interval("normal_reference", "21:11:25", "21:13:15"),
            Interval("transition", "21:13:15", "21:13:45", "exclude"),
            Interval("left_load_bias", "21:13:45", "21:14:10"),
            Interval("recovery", "21:14:10", "21:14:30"),
            Interval("right_load_bias", "21:14:30", "21:14:50"),
            Interval("recovery", "21:14:50", "21:15:00"),
            Interval("left_forefoot_high", "21:15:00", "21:15:20"),
            Interval("recovery", "21:15:20", "21:15:30"),
            Interval("right_forefoot_high", "21:15:30", "21:16:00"),
            Interval("recovery", "21:16:00", "21:16:05"),
            Interval("both_forefoot_high", "21:16:05", "21:16:25"),
            Interval("recovery", "21:16:25", "21:17:12", "medium"),
            Interval("right_medial_load", "21:17:16", "21:17:30", "medium"),
            Interval("right_lateral_load", "21:17:42", "21:17:55", "medium"),
            Interval("left_medial_load", "21:18:08", "21:18:13", "low"),
            Interval("left_lateral_load", "21:18:13", "21:18:21", "low"),
        ],
    },
    "person_b_session_01": {
        "window": ("21:40:00", "21:44:30"),
        "notes": [
            "Baseline completed. This is the primary threshold-tuning session.",
            "Some movement occurred before left load bias; labeled transition windows are excluded.",
        ],
        "intervals": [
            Interval("normal_reference", "21:40:00", "21:40:15"),
            Interval("transition", "21:40:15", "21:40:25", "exclude"),
            Interval("left_load_bias", "21:40:25", "21:40:45"),
            Interval("recovery", "21:40:45", "21:40:55"),
            Interval("right_load_bias", "21:40:55", "21:41:10"),
            Interval("recovery", "21:41:10", "21:41:30"),
            Interval("left_forefoot_high", "21:41:30", "21:41:45"),
            Interval("recovery", "21:41:45", "21:42:00"),
            Interval("right_forefoot_high", "21:42:00", "21:42:20"),
            Interval("recovery", "21:42:20", "21:42:40"),
            Interval("both_forefoot_high", "21:42:40", "21:42:55"),
            Interval("recovery", "21:42:55", "21:43:10"),
            Interval("left_medial_load", "21:43:10", "21:43:25"),
            Interval("transition", "21:43:25", "21:43:30", "exclude"),
            Interval("left_lateral_load", "21:43:30", "21:43:50"),
            Interval("right_medial_load", "21:43:55", "21:44:10"),
            Interval("right_lateral_load", "21:44:10", "21:44:30"),
        ],
    },
}


CSV_COLUMNS = [
    "session_id",
    "label",
    "label_confidence",
    "local_time",
    "timestamp_ms",
    "side",
    "device_id",
    "sync_id",
    "packet_seq",
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
    "quality_flags",
    "source",
]


def epoch_ms(value: str) -> int:
    moment = datetime.combine(
        SESSION_DATE, time.fromisoformat(value), LOCAL_TIMEZONE
    )
    return int(moment.timestamp() * 1000)


def label_for(timestamp_ms: int, intervals: list[Interval]) -> tuple[str, str]:
    for interval in intervals:
        start_ms, end_ms = interval.bounds_ms()
        if start_ms <= timestamp_ms < end_ms:
            return interval.label, interval.confidence
    return "transition_or_unlabeled", "exclude"


def export_session(
    connection: sqlite3.Connection,
    session_id: str,
    definition: dict,
    output_dir: Path,
) -> int:
    start_ms, end_ms = (epoch_ms(value) for value in definition["window"])
    rows = connection.execute(
        """
        SELECT timestamp_ms, side, device_id, sync_id, packet_seq,
               p1, p2, p3, p4, p5, p6,
               t1, t2, t3, t4,
               ax, ay, az, gx, gy, gz, quality_flags, source
        FROM sensor_frames
        WHERE source = 'ble' AND timestamp_ms >= ? AND timestamp_ms < ?
        ORDER BY timestamp_ms, side
        """,
        (start_ms, end_ms),
    ).fetchall()

    target = output_dir / f"{session_id}.csv"
    with target.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for row in rows:
            item = dict(row)
            label, confidence = label_for(
                item["timestamp_ms"], definition["intervals"]
            )
            local_time = datetime.fromtimestamp(
                item["timestamp_ms"] / 1000, LOCAL_TIMEZONE
            ).isoformat(timespec="milliseconds")
            writer.writerow(
                {
                    "session_id": session_id,
                    "label": label,
                    "label_confidence": confidence,
                    "local_time": local_time,
                    **item,
                }
            )
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default="backend/data/footguard.db")
    parser.add_argument(
        "--output", default="sample_data/labeled_20260814"
    )
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(args.database)
    connection.row_factory = sqlite3.Row

    counts = {}
    for session_id, definition in SESSIONS.items():
        counts[session_id] = export_session(
            connection, session_id, definition, output_dir
        )

    labels = {
        "timezone": "Asia/Shanghai (UTC+08:00)",
        "date": SESSION_DATE.isoformat(),
        "sessions": {
            session_id: {
                "window": definition["window"],
                "row_count": counts[session_id],
                "notes": definition["notes"],
                "intervals": [interval.__dict__ for interval in definition["intervals"]],
            }
            for session_id, definition in SESSIONS.items()
        },
    }
    (output_dir / "labels.json").write_text(
        json.dumps(labels, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(counts, ensure_ascii=False))


if __name__ == "__main__":
    main()
