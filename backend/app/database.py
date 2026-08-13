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
        columns = {column["name"] for column in inspect(engine).get_columns("risk_events")}
        if "risk_components_json" not in columns:
            with engine.begin() as connection:
                connection.execute(
                    text(
                        "ALTER TABLE risk_events ADD COLUMN "
                        "risk_components_json VARCHAR(1024) NOT NULL DEFAULT '[]'"
                    )
                )
    return engine, factory


def get_db(request: Request) -> Generator[Session, None, None]:
    session = request.app.state.session_factory()
    try:
        yield session
    finally:
        session.close()
