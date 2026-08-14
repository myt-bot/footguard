from __future__ import annotations

from collections.abc import Generator

from fastapi import Request
from sqlalchemy import Engine, create_engine, inspect, text
from sqlalchemy.orm import Session, sessionmaker

from backend.app.models import Base


def create_database(url: str) -> tuple[Engine, sessionmaker[Session]]:
    connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}
    engine = create_engine(url, connect_args=connect_args)
    factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
    Base.metadata.create_all(engine)
    # create_all does not add columns to an existing SQLite database. Keep the
    # competition database forward-compatible without deleting event history.
    if engine.dialect.name == "sqlite":
        migrations = {
            "risk_events": {
                "risk_components_json": "VARCHAR(1024) NOT NULL DEFAULT '[]'",
            },
            "calibration_profiles": {
                "empty_temperature_delta_json": "VARCHAR(256) NOT NULL DEFAULT '[0,0,0,0]'",
                "empty_temperature_mad_json": "VARCHAR(256) NOT NULL DEFAULT '[0,0,0,0]'",
                "empty_temperature_slope_json": "VARCHAR(256) NOT NULL DEFAULT '[0,0,0,0]'",
                "temperature_offset_status_json": "VARCHAR(256) NOT NULL DEFAULT '[\"unstable\",\"unstable\",\"unstable\",\"unstable\"]'",
                "wearing_temperature_mad_json": "VARCHAR(256) NOT NULL DEFAULT '[0,0,0,0]'",
            },
        }
        with engine.begin() as connection:
            for table, table_migrations in migrations.items():
                columns = {column["name"] for column in inspect(engine).get_columns(table)}
                for column, definition in table_migrations.items():
                    if column not in columns:
                        connection.execute(text(f"ALTER TABLE {table} ADD COLUMN {column} {definition}"))
    return engine, factory


def get_db(request: Request) -> Generator[Session, None, None]:
    session = request.app.state.session_factory()
    try:
        yield session
    finally:
        session.close()
