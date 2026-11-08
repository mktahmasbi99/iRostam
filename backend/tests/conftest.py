from __future__ import annotations

from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from app.config import Settings
from app.database import RostamDatabase


@pytest.fixture
def database(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> RostamDatabase:
    timezone = ZoneInfo("Europe/Warsaw")
    database = RostamDatabase(
        Settings(
            database_path=tmp_path / "rostam.sqlite3",
            timezone_name="Europe/Warsaw",
            timezone=timezone,
        )
    )
    monkeypatch.setattr(database, "now_local", lambda: datetime(2026, 11, 9, 12, tzinfo=timezone))
    return database
