from __future__ import annotations

import json
import io
import os
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from codex_token_counter.cli import stream
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


def session_meta_line(cwd: str) -> str:
    return json.dumps({"type": "session_meta", "payload": {"cwd": cwd}}) + "\n"


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

    def test_partial_final_line_is_retried_when_completed(self) -> None:
        installed = datetime.now(timezone.utc)
        path = self.sessions / "partial.jsonl"
        prefix = token_line(installed + timedelta(seconds=1), 120).encode("utf-8")
        pending = token_line(installed + timedelta(seconds=2), 250).encode("utf-8")
        split = len(pending) // 2
        path.write_bytes(prefix + pending[:split])

        first = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(first.tokens_added, 120)
        self.assertEqual(self.store.get_file_cursor(str(path.resolve())), len(prefix))
        with path.open("ab") as handle:
            handle.write(pending[split:])
        second = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        third = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(second.tokens_added, 250)
        self.assertEqual(third.tokens_added, 0)
        self.assertEqual(self.store.totals(installed).total, 370)

    def test_complete_json_waits_for_newline_before_advancing_cursor(self) -> None:
        installed = datetime.now(timezone.utc)
        path = self.sessions / "unterminated.jsonl"
        pending = token_line(installed + timedelta(seconds=1), 250).encode("utf-8")
        path.write_bytes(pending[:-1])
        first = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(first.tokens_added, 0)
        self.assertEqual(self.store.get_file_cursor(str(path.resolve())), 0)
        with path.open("ab") as handle:
            handle.write(b"\n")
        second = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(second.tokens_added, 250)

    def test_partial_utf8_final_line_is_retried(self) -> None:
        installed = datetime.now(timezone.utc)
        path = self.sessions / "utf8.jsonl"
        record = json.loads(token_line(installed + timedelta(seconds=1), 250))
        record["note"] = "中文"
        pending = (json.dumps(record, ensure_ascii=False) + "\n").encode("utf-8")
        split = pending.index("中".encode("utf-8")) + 1
        path.write_bytes(pending[:split])
        scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(self.store.get_file_cursor(str(path.resolve())), 0)
        with path.open("ab") as handle:
            handle.write(pending[split:])
        result = scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)
        self.assertEqual(result.tokens_added, 250)

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

    def test_groups_top_projects_by_session_working_directory(self) -> None:
        now = datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
        installed = now - timedelta(days=2)
        first = self.sessions / "first.jsonl"
        second = self.sessions / "second.jsonl"
        third = self.sessions / "third.jsonl"
        first.write_text(
            session_meta_line("/work/alpha")
            + token_line(now - timedelta(days=1), 300),
            encoding="utf-8",
        )
        second.write_text(
            session_meta_line("/work/beta")
            + token_line(now, 700),
            encoding="utf-8",
        )
        third.write_text(
            session_meta_line("/work/alpha")
            + token_line(now, 500),
            encoding="utf-8",
        )
        scan_sessions(store=self.store, sessions_root=self.sessions, installed_at=installed)

        projects = self.store.top_projects(3, now=now)
        self.assertEqual(
            [(item.name, item.total, item.today) for item in projects],
            [("alpha", 800, 500), ("beta", 700, 700)],
        )
        self.assertEqual(
            [item.name for item in self.store.top_projects(now=now, order_by="today")],
            ["beta", "alpha"],
        )

    def test_same_name_projects_stay_separate_and_ties_are_stable(self) -> None:
        now = datetime.now().astimezone()
        for index, project_path in enumerate(["/work/z/alpha", "/work/a/alpha"]):
            self.store.add_usage_event(
                event_id=f"project-{index}",
                occurred_at=now,
                session_path=f"session-{index}",
                byte_offset=0,
                total_tokens=300,
                project_path=project_path,
                project_name="alpha",
            )

        projects = self.store.top_projects(now=now)
        self.assertEqual(
            [(item.path, item.total, item.today) for item in projects],
            [("/work/a/alpha", 300, 300), ("/work/z/alpha", 300, 300)],
        )
        self.assertEqual(self.store.top_projects(1, now=now), projects[:1])
        self.assertEqual(self.store.top_projects(now=now, order_by="today"), projects)

    def test_project_ranking_rejects_unknown_order(self) -> None:
        with self.assertRaisesRegex(ValueError, "order_by"):
            self.store.top_projects(order_by="invalid")

    def test_sidebar_names_only_change_display_not_history_or_identity(self) -> None:
        now = datetime.now().astimezone()
        for index, path in enumerate(["/work/old-folder", "/other/old-folder"]):
            self.store.add_usage_event(
                event_id=f"named-{index}", occurred_at=now, session_path=f"session-{index}",
                byte_offset=0, total_tokens=100 + index, project_path=path, project_name="old-folder",
            )
        before = [tuple(row) for row in self.store.connection.execute("SELECT * FROM usage_events ORDER BY event_id")]
        labels = {os.path.normpath(path): "中文项目示例"
                  for path in ("/work/old-folder", "/other/old-folder")}
        projects = self.store.top_projects(None, now=now, order_by="today", project_labels=labels)
        self.assertEqual(len(projects), 2)
        self.assertEqual([item.name for item in projects], ["中文项目示例"] * 2)
        self.assertEqual([item.path for item in projects], ["/other/old-folder", "/work/old-folder"])
        self.assertEqual(sum(item.total for item in projects), self.store.totals(now).total)
        self.assertEqual(sum(item.today for item in projects), self.store.totals(now).today)
        after = [tuple(row) for row in self.store.connection.execute("SELECT * FROM usage_events ORDER BY event_id")]
        self.assertEqual(before, after)

    def test_same_path_with_historical_names_returns_one_project(self) -> None:
        now = datetime.now().astimezone()
        for index, name in enumerate(["old name", "new name"]):
            self.store.add_usage_event(
                event_id=f"renamed-{index}", occurred_at=now, session_path=f"session-{index}",
                byte_offset=0, total_tokens=100, project_path="/work/project", project_name=name,
            )
        projects = self.store.top_projects(now=now, project_labels={os.path.normpath("/work/project"): "侧栏项目名"})
        self.assertEqual([(p.path, p.name, p.total, p.today) for p in projects],
                         [("/work/project", "侧栏项目名", 200, 200)])
        self.assertEqual(self.store.top_projects(now=now)[0].name, "project")

    def test_stream_refreshes_sidebar_name_even_without_new_tokens(self) -> None:
        now = datetime.now().astimezone()
        self.store.ensure_initialized(now - timedelta(days=1))
        self.store.add_usage_event(
            event_id="rename-stream", occurred_at=now, session_path="session",
            byte_offset=0, total_tokens=200, project_path="/work/project", project_name="project",
        )
        args = Namespace(db=str(self.store.path), sessions=str(self.sessions), interval=300)
        output = io.StringIO()
        with (
            patch("codex_token_counter.cli.scan_sessions"),
            patch("codex_token_counter.cli.load_project_labels", side_effect=[
                {os.path.normpath("/work/project"): "原项目名"},
                {os.path.normpath("/work/project"): "新项目名"},
            ]) as load_names,
            patch("codex_token_counter.cli.time.sleep", side_effect=[None, KeyboardInterrupt]),
            redirect_stdout(output),
        ):
            self.assertEqual(stream(args), 0)
        snapshots = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(snapshots), 2)
        self.assertEqual([item["projects"][0]["name"] for item in snapshots], ["原项目名", "新项目名"])
        for item in snapshots:
            self.assertEqual((item["today"], item["total"], item["event_count"]), (200, 200, 1))
            self.assertEqual(item["projects"][0]["path"], "/work/project")
        self.assertEqual(load_names.call_args.args, (self.root.resolve(),))

    def test_all_projects_include_beyond_top_three_with_today_and_total(self) -> None:
        now = datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
        usage = [
            ("alpha", 1000, 100),
            ("beta", 500, 400),
            ("gamma", 300, 500),
            ("delta", 200, 10),
            ("epsilon", 0, 200),
        ]
        for name, yesterday_tokens, today_tokens in usage:
            for day, tokens in [(1, yesterday_tokens), (0, today_tokens)]:
                self.store.add_usage_event(
                    event_id=f"{name}-{day}",
                    occurred_at=now - timedelta(days=day),
                    session_path=f"session-{name}",
                    byte_offset=day,
                    total_tokens=tokens,
                    project_path=f"/work/{name}",
                    project_name=name,
                )

        projects = self.store.top_projects(limit=None, now=now, order_by="today")
        self.assertEqual(
            [(item.name, item.total, item.today) for item in projects],
            [
                ("gamma", 800, 500),
                ("beta", 900, 400),
                ("epsilon", 200, 200),
                ("alpha", 1100, 100),
                ("delta", 210, 10),
            ],
        )
        self.assertEqual(self.store.top_projects(now=now, order_by="today"), projects[:3])
        totals = self.store.totals(now)
        self.assertEqual(sum(project.total for project in projects), totals.total)
        self.assertEqual(sum(project.today for project in projects), totals.today)

    def test_project_today_resets_at_midnight_without_changing_total(self) -> None:
        before = datetime.now().astimezone().replace(hour=23, minute=59, second=59, microsecond=0)
        after = before + timedelta(seconds=1)
        self.store.add_usage_event(
            event_id="before-midnight",
            occurred_at=before,
            session_path="session",
            byte_offset=0,
            total_tokens=300,
            project_path="/work/alpha",
            project_name="alpha",
        )

        previous = self.store.top_projects(now=before)[0]
        current = self.store.top_projects(now=after)[0]
        self.assertEqual((previous.total, previous.today), (300, 300))
        self.assertEqual((current.total, current.today), (300, 0))
        self.assertEqual(current.today, self.store.totals(after).today)

    def test_today_ranking_falls_back_to_total_after_midnight(self) -> None:
        before = datetime.now().astimezone().replace(hour=23, minute=59, second=59, microsecond=0)
        after = before + timedelta(seconds=1)
        for name, day, tokens in [("alpha", 1, 900), ("alpha", 0, 100), ("beta", 0, 300)]:
            self.store.add_usage_event(
                event_id=f"{name}-{day}",
                occurred_at=before - timedelta(days=day),
                session_path=f"session-{name}",
                byte_offset=day,
                total_tokens=tokens,
                project_path=f"/work/{name}",
                project_name=name,
            )

        previous = self.store.top_projects(now=before, order_by="today")
        current = self.store.top_projects(now=after, order_by="today")
        self.assertEqual(
            [(item.name, item.total, item.today) for item in previous],
            [("beta", 300, 300), ("alpha", 1000, 100)],
        )
        self.assertEqual(
            [(item.name, item.total, item.today) for item in current],
            [("alpha", 1000, 0), ("beta", 300, 0)],
        )

    def test_stream_returns_all_projects_ranked_by_today(self) -> None:
        now = datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
        self.store.ensure_initialized(now - timedelta(days=2))
        for name, yesterday_tokens, today_tokens in [
            ("alpha", 1000, 100),
            ("beta", 200, 200),
            ("gamma", 300, 200),
            ("delta", 0, 300),
        ]:
            for day, tokens in [(1, yesterday_tokens), (0, today_tokens)]:
                self.store.add_usage_event(
                    event_id=f"{name}-{day}",
                    occurred_at=now - timedelta(days=day),
                    session_path=f"session-{name}",
                    byte_offset=day,
                    total_tokens=tokens,
                    project_path=f"/work/{name}",
                    project_name=name,
                )

        args = Namespace(db=str(self.store.path), sessions=str(self.sessions), interval=240)
        output = io.StringIO()
        with (
            patch("codex_token_counter.cli.datetime") as clock,
            patch("codex_token_counter.cli.scan_sessions"),
            patch("codex_token_counter.cli.time.sleep", side_effect=KeyboardInterrupt),
            redirect_stdout(output),
        ):
            clock.now.return_value = now
            self.assertEqual(stream(args), 0)

        snapshot = json.loads(output.getvalue())
        self.assertEqual(
            [(item["name"], item["total"], item["today"]) for item in snapshot["projects"]],
            [("delta", 300, 300), ("gamma", 500, 200), ("beta", 400, 200), ("alpha", 1100, 100)],
        )
        self.assertEqual(sum(item["today"] for item in snapshot["projects"]), snapshot["today"])
        self.assertEqual(sum(item["total"] for item in snapshot["projects"]), snapshot["total"])

    def test_stream_emits_project_today_and_midnight_reset(self) -> None:
        before = datetime.now().astimezone().replace(hour=23, minute=59, second=59, microsecond=0)
        after = before + timedelta(seconds=1)
        self.store.ensure_initialized(before - timedelta(days=1))
        self.store.add_usage_event(
            event_id="stream-midnight",
            occurred_at=before,
            session_path="session",
            byte_offset=0,
            total_tokens=300,
            project_path="/work/alpha",
            project_name="alpha",
        )
        args = Namespace(db=str(self.store.path), sessions=str(self.sessions), interval=0.5)
        output = io.StringIO()
        with (
            patch("codex_token_counter.cli.datetime") as clock,
            patch("codex_token_counter.cli.scan_sessions"),
            patch("codex_token_counter.cli.time.sleep", side_effect=[None, KeyboardInterrupt]),
            redirect_stdout(output),
        ):
            clock.now.side_effect = [before, before, after]
            self.assertEqual(stream(args), 0)
            self.assertEqual(clock.now.call_count, 3)

        snapshots = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(snapshots), 2)
        self.assertEqual(
            snapshots[0]["projects"],
            [{"name": "alpha", "path": "/work/alpha", "total": 300, "today": 300}],
        )
        self.assertEqual(snapshots[1]["projects"][0]["today"], 0)
        self.assertEqual(snapshots[1]["projects"][0]["total"], 300)
        self.assertEqual([item["today"] for item in snapshots], [300, 0])


if __name__ == "__main__":
    unittest.main()
