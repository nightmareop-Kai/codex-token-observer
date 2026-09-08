from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from .collector import parse_timestamp, scan_sessions
from .project_names import load_project_labels
from .storage import TokenStore


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB = PROJECT_ROOT / "data" / "token_counter.sqlite3"
DEFAULT_SESSIONS = Path.home() / ".codex" / "sessions"


def format_tokens(value: int) -> str:
    return f"{value:,}".replace(",", " ")


def render_status(store: TokenStore, *, clear: bool = False) -> None:
    totals = store.totals(datetime.now().astimezone())
    if clear and sys.stdout.isatty():
        print("\033[2J\033[H", end="")
    print("ZUNO / CODEX TOKEN COUNTER")
    print()
    print(f"TODAY  {format_tokens(totals.today):>18}")
    print(f"TOTAL  {format_tokens(totals.total):>18}")
    print()
    print(f"events {totals.event_count}")
    print(f"last   {totals.last_event_at or 'waiting for Codex token activity'}")


def open_store(args: argparse.Namespace) -> TokenStore:
    return TokenStore(Path(args.db).expanduser().resolve())


def initialize(args: argparse.Namespace) -> int:
    store = open_store(args)
    try:
        installed_at = store.ensure_initialized(datetime.now().astimezone())
        print(f"initialized: {installed_at}")
        print(f"database:    {store.path}")
        print(f"sessions:    {Path(args.sessions).expanduser().resolve()}")
        render_status(store)
        return 0
    finally:
        store.close()


def scan_once(args: argparse.Namespace, *, show_scan: bool = True) -> int:
    store = open_store(args)
    try:
        installed_at_text = store.ensure_initialized(datetime.now().astimezone())
        result = scan_sessions(
            store=store,
            sessions_root=Path(args.sessions).expanduser().resolve(),
            installed_at=parse_timestamp(installed_at_text),
        )
        render_status(store)
        if show_scan:
            print()
            print(
                f"scan: {result.files_scanned} files, "
                f"{result.token_events_added} new events, "
                f"+{format_tokens(result.tokens_added)} tokens"
            )
        return 0
    finally:
        store.close()


def watch(args: argparse.Namespace) -> int:
    store = open_store(args)
    try:
        installed_at_text = store.ensure_initialized(datetime.now().astimezone())
        installed_at = parse_timestamp(installed_at_text)
        print("Watching local Codex token events. Press Ctrl-C to stop.")
        while True:
            result = scan_sessions(
                store=store,
                sessions_root=Path(args.sessions).expanduser().resolve(),
                installed_at=installed_at,
            )
            render_status(store, clear=True)
            if result.token_events_added:
                print(
                    f"new    +{format_tokens(result.tokens_added)} "
                    f"({result.token_events_added} event(s))"
                )
            else:
                print("new    waiting")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0
    finally:
        store.close()


def stream(args: argparse.Namespace) -> int:
    """Continuously emit machine-readable snapshots for the desktop observer."""
    store = open_store(args)
    network = None
    try:
        installed_at_text = store.ensure_initialized(datetime.now().astimezone())
        installed_at = parse_timestamp(installed_at_text)
        if getattr(args, "leaderboard", False):
            from .leaderboard import LeaderboardWorker

            network = LeaderboardWorker(store.path)
            network.start()
        previous: tuple | None = None
        next_scan = 0.0
        quota = None
        while True:
            if network is None or time.monotonic() >= next_scan:
                scan_sessions(
                    store=store,
                    sessions_root=Path(args.sessions).expanduser().resolve(),
                    installed_at=installed_at,
                )
                now = datetime.now().astimezone()
                totals = store.totals(now)
                labels = load_project_labels(Path(args.sessions).expanduser().resolve().parent)
                projects = store.top_projects(None, now=now, order_by="today", project_labels=labels)
                if getattr(args, "account_quota", False):
                    from .quota import poll_weekly_quota

                    quota = poll_weekly_quota(store, now=now)
                next_scan = time.monotonic() + max(0.05, args.interval)
            network_snapshot = network.snapshot() if network else {}
            project_snapshot = tuple(
                (project.path, project.name, project.total, project.today)
                for project in projects
            )
            snapshot = (totals.today, totals.total, totals.event_count, totals.last_event_at,
                        project_snapshot, json.dumps(quota, sort_keys=True),
                        json.dumps(network_snapshot, sort_keys=True))
            if snapshot != previous:
                print(json.dumps({
                    "today": totals.today,
                    "total": totals.total,
                    "event_count": totals.event_count,
                    "last_event_at": totals.last_event_at,
                    "quota": quota,
                    **network_snapshot,
                    "projects": [
                        {
                            "name": project.name,
                            "path": project.path,
                            "total": project.total,
                            "today": project.today,
                        }
                        for project in projects
                    ],
                }, separators=(",", ":")), flush=True)
                previous = snapshot
            delay = max(0, next_scan - time.monotonic())
            if network:
                network.changed.wait(min(delay, 1))
                network.changed.clear()
            else:
                time.sleep(delay)
    except KeyboardInterrupt:
        return 0
    finally:
        if network:
            network.stop()
        store.close()


def profile_command(args: argparse.Namespace) -> int:
    from .leaderboard import profile_status, register_profile, set_paused

    db_path = Path(args.db).expanduser().resolve()
    if args.command == "profile-register":
        profile = register_profile(db_path, args.nickname)
    elif args.command == "profile-pause":
        profile = set_paused(db_path, True)
    elif args.command == "profile-resume":
        profile = set_paused(db_path, False)
    else:
        profile = profile_status(db_path)
    print(json.dumps({"profile": profile}, ensure_ascii=False, separators=(",", ":")), flush=True)
    return 0 if not profile.get("error") else 1


def leaderboard_read(args: argparse.Namespace) -> int:
    from .leaderboard import read_leaderboard

    board = read_leaderboard(Path(args.db).expanduser().resolve(), offset=args.offset, limit=args.limit)
    print(json.dumps(board, ensure_ascii=False, separators=(",", ":")), flush=True)
    return 0 if board["status"] == "ok" else 1


def simulate(args: argparse.Namespace) -> int:
    store = open_store(args)
    try:
        store.ensure_initialized(datetime.now().astimezone())
        now = datetime.now().astimezone()
        event_id = f"simulation:{now.isoformat()}:{args.tokens}:{os.getpid()}"
        store.add_usage_event(
            event_id=event_id,
            occurred_at=now,
            session_path="simulation",
            byte_offset=0,
            total_tokens=args.tokens,
            input_tokens=args.tokens,
        )
        render_status(store)
        return 0
    finally:
        store.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Local Codex TODAY/TOTAL token counter")
    parser.add_argument("--db", default=str(DEFAULT_DB), help="SQLite database path")
    parser.add_argument(
        "--sessions", default=str(DEFAULT_SESSIONS), help="Codex sessions root"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("init", help="Initialize a zero-based local counter")
    subparsers.add_parser("status", help="Scan once and print TODAY/TOTAL")
    watch_parser = subparsers.add_parser("watch", help="Continuously watch Codex activity")
    watch_parser.add_argument("--interval", type=float, default=0.75)
    stream_parser = subparsers.add_parser("stream", help="Continuously emit JSON snapshots")
    stream_parser.add_argument("--interval", type=float, default=0.5)
    stream_parser.add_argument("--account-quota", action="store_true", help="Read signed-in Codex weekly quota")
    stream_parser.add_argument("--leaderboard", action="store_true", help="Include public leaderboard and profile state")
    profile_parser = subparsers.add_parser("profile-register", help="Create a permanent public nickname and join")
    profile_parser.add_argument("--nickname", required=True)
    subparsers.add_parser("profile-status", help="Read sanitized local Zuno profile without network access")
    subparsers.add_parser("profile-pause", help="Pause uploads without deleting identity or usage")
    subparsers.add_parser("profile-resume", help="Resume uploads with the existing identity")
    board_parser = subparsers.add_parser("leaderboard-read", help="Read the public yesterday leaderboard")
    board_parser.add_argument("--offset", type=int, default=0)
    board_parser.add_argument("--limit", type=int, default=50)
    simulate_parser = subparsers.add_parser("simulate", help="Add a synthetic token event")
    simulate_parser.add_argument("tokens", type=int)
    return parser


def main() -> int:
    # Native desktop clients read a UTF-8 JSON protocol. Redirected Windows
    # streams otherwise inherit the locale code page, which cannot encode many
    # valid permanent nicknames. Establish the wire encoding at every CLI entry.
    # Embedded callers/tests may supply StringIO; leave their streams intact.
    for output, errors in ((sys.stdout, "strict"), (sys.stderr, "backslashreplace")):
        reconfigure = getattr(output, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors=errors)
    args = build_parser().parse_args()
    if args.command == "init":
        return initialize(args)
    if args.command == "status":
        return scan_once(args)
    if args.command == "watch":
        return watch(args)
    if args.command == "stream":
        return stream(args)
    if args.command == "simulate":
        return simulate(args)
    if args.command.startswith("profile-"):
        return profile_command(args)
    if args.command == "leaderboard-read":
        return leaderboard_read(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
