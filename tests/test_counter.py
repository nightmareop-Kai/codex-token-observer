from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from codex_token_counter.collector import scan_sessions
from codex_token_counter.storage import TokenStore


def token_line(timestamp: datetime, total: int) -> str:
    record = {
        "timestamp": timestamp.isoformat().replace("+00:00", "Z"),
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {
                    "input_tokens": total - 10,
                    "cached_input_tokens": 0,
                    "output_tokens": 10,
                    "reasoning_output_tokens": 0,
                    "total_tokens": total,
                }
            },
        },
    }
    return json.dumps(record) + "\n"


class CounterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.sessions = self.root / "sessions"
        self.sessions.mkdir()
        self.store = TokenStore(self.root / "counter.sqlite3")

    def tearDown(self) -> None:
        self.store.close()
        self.temp.cleanup()

    def test_counts_only_events_after_install_and_is_idempotent(self) -> None:
        installed = datetime.now(timezone.utc)
        path = self.sessions / "rollout.jsonl"
        path.write_text(
            token_line(installed - timedelta(seconds=1), 100)
            + token_line(installed + timedelta(seconds=1), 250),
            encoding="utf-8",
        )

        first = scan_sessions(
            store=self.store, sessions_root=self.sessions, installed_at=installed
        )
        second = scan_sessions(
            store=self.store, sessions_root=self.sessions, installed_at=installed
        )

        self.assertEqual(first.token_events_added, 1)
        self.assertEqual(first.tokens_added, 250)
        self.assertEqual(second.token_events_added, 0)
        self.assertEqual(self.store.totals(installed).total, 250)

    def test_recovers_events_appended_while_not_running(self) -> None:
        installed = datetime.now(timezone.utc)
        path = self.sessions / "rollout.jsonl"
        path.write_text(token_line(installed + timedelta(seconds=1), 120), encoding="utf-8")
        scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(token_line(installed + timedelta(seconds=2), 80))
        result = scan_sessions(
            store=self.store, sessions_root=self.sessions, installed_at=installed
        )
        self.assertEqual(result.tokens_added, 80)
        self.assertEqual(self.store.totals(installed).total, 200)

    def test_today_uses_local_calendar_day(self) -> None:
        now = datetime.now().astimezone()
        self.store.add_usage_event(
            event_id="today",
            occurred_at=now,
            session_path="test",
            byte_offset=0,
            total_tokens=300,
        )
        self.store.add_usage_event(
            event_id="yesterday",
            occurred_at=now - timedelta(days=1),
            session_path="test",
            byte_offset=1,
            total_tokens=700,
        )
        totals = self.store.totals(now)
        self.assertEqual(totals.today, 300)
        self.assertEqual(totals.total, 1000)


if __name__ == "__main__":
    unittest.main()
