from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from .collector import parse_timestamp, scan_sessions
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
    print("CODEX TOKEN COUNTER")
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
    try:
        installed_at_text = store.ensure_initialized(datetime.now().astimezone())
        installed_at = parse_timestamp(installed_at_text)
        previous: tuple[int, int, int, str | None] | None = None
        while True:
            scan_sessions(
                store=store,
                sessions_root=Path(args.sessions).expanduser().resolve(),
                installed_at=installed_at,
            )
            totals = store.totals(datetime.now().astimezone())
            snapshot = (totals.today, totals.total, totals.event_count, totals.last_event_at)
            if snapshot != previous:
                print(json.dumps({
                    "today": totals.today,
                    "total": totals.total,
                    "event_count": totals.event_count,
                    "last_event_at": totals.last_event_at,
                }, separators=(",", ":")), flush=True)
                previous = snapshot
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        store.close()


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
    simulate_parser = subparsers.add_parser("simulate", help="Add a synthetic token event")
    simulate_parser.add_argument("tokens", type=int)
    return parser


def main() -> int:
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
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
