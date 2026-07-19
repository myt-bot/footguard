from __future__ import annotations

from fastapi import FastAPI

from .config import DATA_DIR, database_url
from .database import create_database
from .routers import commands, events, feedback, health, realtime, sensor


def create_app(database_url_override: str | None = None) -> FastAPI:
    url = database_url_override or database_url()
    if url.startswith("sqlite:///") and ":memory:" not in url:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
    engine, session_factory = create_database(url)
    application = FastAPI(
        title="FootGuard Backend API",
        version="0.1.0",
        description="FootGuard dual-foot sensor ingestion and command API (protocol v1)",
    )
    application.state.engine = engine
    application.state.session_factory = session_factory
    application.include_router(health.router)
    application.include_router(sensor.router)
    application.include_router(realtime.router)
    application.include_router(events.router)
    application.include_router(commands.router)
    application.include_router(feedback.router)
    return application


app = create_app()
