from __future__ import annotations

import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "backend" / "data"
DEFAULT_DATABASE_URL = f"sqlite:///{(DATA_DIR / 'footguard.db').as_posix()}"


def database_url() -> str:
    return os.getenv("FOOTGUARD_DATABASE_URL", DEFAULT_DATABASE_URL)
