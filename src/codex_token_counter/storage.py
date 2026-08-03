from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


@dataclass(frozen=True)
class Totals:
    today: int
    total: int
    event_count: int
    last_event_at: str | None


class TokenStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self._migrate()

    def close(self) -> None:
        self.connection.close()

    def _migrate(self) -> None:
        self.connection.executescript(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;

            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS usage_events (
                event_id TEXT PRIMARY KEY,
                occurred_at TEXT NOT NULL,
                local_date TEXT NOT NULL,
                session_path TEXT NOT NULL,
                byte_offset INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL CHECK(total_tokens >= 0),
                input_tokens INTEGER NOT NULL DEFAULT 0,
                cached_input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_output_tokens INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS usage_events_local_date_idx
                ON usage_events(local_date);

            CREATE TABLE IF NOT EXISTS file_cursors (
                session_path TEXT PRIMARY KEY,
                byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
                updated_at TEXT NOT NULL
            );
            """
        )
        self.connection.commit()

    def get_file_cursor(self, session_path: str) -> int:
        row = self.connection.execute(
            "SELECT byte_offset FROM file_cursors WHERE session_path = ?",
            (session_path,),
        ).fetchone()
        return 0 if row is None else int(row["byte_offset"])

    def set_file_cursor(self, session_path: str, byte_offset: int) -> None:
        self.connection.execute(
            """
            INSERT INTO file_cursors(session_path, byte_offset, updated_at)
            VALUES(?, ?, ?)
            ON CONFLICT(session_path) DO UPDATE SET
                byte_offset = excluded.byte_offset,
                updated_at = excluded.updated_at
            """,
            (
                session_path,
                int(byte_offset),
                datetime.now().astimezone().isoformat(),
            ),
        )
        self.connection.commit()

    def ensure_initialized(self, now: datetime) -> str:
        installed_at = self.get_metadata("installed_at")
        if installed_at is None:
            installed_at = now.astimezone().isoformat()
            self.set_metadata("installed_at", installed_at)
        return installed_at

    def get_metadata(self, key: str) -> str | None:
        row = self.connection.execute(
            "SELECT value FROM metadata WHERE key = ?", (key,)
        ).fetchone()
        return None if row is None else str(row["value"])

    def set_metadata(self, key: str, value: str) -> None:
        self.connection.execute(
            """
            INSERT INTO metadata(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            (key, value),
        )
        self.connection.commit()

    def add_usage_event(
        self,
        *,
        event_id: str,
        occurred_at: datetime,
        session_path: str,
        byte_offset: int,
        total_tokens: int,
        input_tokens: int = 0,
        cached_input_tokens: int = 0,
        output_tokens: int = 0,
        reasoning_output_tokens: int = 0,
    ) -> bool:
        local_time = occurred_at.astimezone()
        cursor = self.connection.execute(
            """
            INSERT OR IGNORE INTO usage_events(
                event_id, occurred_at, local_date, session_path, byte_offset,
                total_tokens, input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                event_id,
                occurred_at.isoformat(),
                local_time.date().isoformat(),
                session_path,
                byte_offset,
                int(total_tokens),
                int(input_tokens),
                int(cached_input_tokens),
                int(output_tokens),
                int(reasoning_output_tokens),
                datetime.now().astimezone().isoformat(),
            ),
        )
        self.connection.commit()
        return cursor.rowcount == 1

    def totals(self, now: datetime) -> Totals:
        today = now.astimezone().date().isoformat()
        row = self.connection.execute(
            """
            SELECT
                COALESCE(SUM(CASE WHEN local_date = ? THEN total_tokens ELSE 0 END), 0) AS today,
                COALESCE(SUM(total_tokens), 0) AS total,
                COUNT(*) AS event_count,
                MAX(occurred_at) AS last_event_at
            FROM usage_events
            """,
            (today,),
        ).fetchone()
        return Totals(
            today=int(row["today"]),
            total=int(row["total"]),
            event_count=int(row["event_count"]),
            last_event_at=row["last_event_at"],
        )
