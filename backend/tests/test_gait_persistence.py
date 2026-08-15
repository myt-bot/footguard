from __future__ import annotations

from sqlalchemy import func, select

from backend.app.database import create_database
from backend.app.models import GaitEpisode
from backend.app.schemas import GaitEpisodeSummary, GaitIssue
from backend.app.services.risk_service import (
    _episode_to_model,
    _persist_gait_episode,
    gait_history_summary,
)


def _episode(episode_id: str, ended_at_ms: int, steps: int) -> GaitEpisodeSummary:
    return GaitEpisodeSummary(
        episode_id=episode_id,
        started_at_ms=1_000,
        ended_at_ms=ended_at_ms,
        duration_ms=ended_at_ms - 1_000,
        step_count=steps,
        left_steps=steps // 2,
        right_steps=steps - steps // 2,
        cadence_spm=80.0,
        step_interval_cv=0.1,
        left_load_index=1.2,
        right_load_index=0.8,
        load_asymmetry=0.2,
        left_forefoot_ratio=0.7,
        right_forefoot_ratio=0.6,
        left_medial_ratio=0.3,
        right_medial_ratio=0.3,
        left_lateral_ratio=0.2,
        right_lateral_ratio=0.2,
        issues=[
            GaitIssue(
                issue_type="walking_load_asymmetry",
                side="left",
                value=0.35,
                threshold=0.30,
            )
        ],
    )


def test_overlapping_gait_rows_are_replaced_by_one_canonical_episode(tmp_path) -> None:
    engine, factory = create_database(f"sqlite:///{tmp_path / 'gait.db'}")
    try:
        with factory() as session:
            session.add(_episode_to_model(_episode("legacy_a", 7_000, 8), 500))
            session.add(_episode_to_model(_episode("legacy_b", 7_060, 10), 500))
            session.commit()

            canonical = _episode("gait_9_1000", 7_100, 12)
            _persist_gait_episode(session, canonical, 500)

            assert session.scalar(select(func.count()).select_from(GaitEpisode)) == 1
            episodes, trend = gait_history_summary(session, 500)
            assert len(episodes) == 1
            assert episodes[0].episode_id == "gait_9_1000"
            assert trend.evidence_episode_count == 1
    finally:
        engine.dispose()
