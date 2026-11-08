import sqlite3
from pathlib import Path

import pytest

from app.database import SEED_EXERCISES

SCHEMA = Path(__file__).parents[2] / "frontend/ios/App/App/irostam-fresh-schema.sql"
STARTER_PROFILE_SCHEMA = """
CREATE TABLE profile_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    height_mm INTEGER CHECK (height_mm > 0),
    date_of_birth TEXT
)
"""


@pytest.mark.parametrize("has_starter_schema", [False, True])
def test_native_fresh_schema_initializes_empty_and_earlier_starter_databases(
    has_starter_schema: bool,
) -> None:
    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA trusted_schema=OFF")
    if has_starter_schema:
        connection.executescript(STARTER_PROFILE_SCHEMA)

    sql = SCHEMA.read_text(encoding="utf-8").replace(
        "__IROSTAM_BOOTSTRAP_NOW__", "2026-01-01T00:00:00.000Z"
    )
    connection.executescript(sql)

    assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
    assert connection.execute("SELECT max(version) FROM schema_migrations").fetchone() == (17,)
    assert connection.execute(
        "SELECT seed_key, name FROM exercises WHERE seed_key IS NOT NULL ORDER BY id"
    ).fetchall() == [(seed_key, name) for seed_key, name, *_ in SEED_EXERCISES]
