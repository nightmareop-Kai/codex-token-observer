from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from .storage import TokenStore


@dataclass(frozen=True)
class ScanResult:
    files_scanned: int
    lines_scanned: int
    token_events_seen: int
    token_events_added: int
    tokens_added: int


def parse_timestamp(value: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        return parsed.astimezone()
    return parsed


def iter_session_files(sessions_root: Path) -> Iterable[Path]:
    if not sessions_root.exists():
        return []
    return sorted(sessions_root.rglob("*.jsonl"))


def _event_from_line(line: str) -> tuple[datetime, dict] | None:
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    if record.get("type") != "event_msg":
        return None
    payload = record.get("payload") or {}
    if payload.get("type") != "token_count":
        return None
    info = payload.get("info") or {}
    usage = info.get("last_token_usage")
    if not isinstance(usage, dict):
        return None
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, str):
        return None
    return parse_timestamp(timestamp), usage


def scan_sessions(
    *, store: TokenStore, sessions_root: Path, installed_at: datetime
) -> ScanResult:
    files_scanned = 0
    lines_scanned = 0
    token_events_seen = 0
    token_events_added = 0
    tokens_added = 0

    for path in iter_session_files(sessions_root):
        files_scanned += 1
        try:
            with path.open("rb") as handle:
                session_path = str(path.resolve())
                cursor = store.get_file_cursor(session_path)
                file_size = path.stat().st_size
                if cursor > file_size:
                    cursor = 0
                handle.seek(cursor)
                while True:
                    offset = handle.tell()
                    raw = handle.readline()
                    if not raw:
                        break
                    lines_scanned += 1
                    try:
                        line = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        continue
                    parsed = _event_from_line(line)
                    if parsed is None:
                        continue
                    token_events_seen += 1
                    occurred_at, usage = parsed
                    if occurred_at < installed_at:
                        continue
                    total_tokens = int(usage.get("total_tokens", 0) or 0)
                    if total_tokens <= 0:
                        continue
                    identity = f"{path.resolve()}:{offset}:{occurred_at.isoformat()}:{total_tokens}"
                    event_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()
                    added = store.add_usage_event(
                        event_id=event_id,
                        occurred_at=occurred_at,
                        session_path=session_path,
                        byte_offset=offset,
                        total_tokens=total_tokens,
                        input_tokens=int(usage.get("input_tokens", 0) or 0),
                        cached_input_tokens=int(usage.get("cached_input_tokens", 0) or 0),
                        output_tokens=int(usage.get("output_tokens", 0) or 0),
                        reasoning_output_tokens=int(
                            usage.get("reasoning_output_tokens", 0) or 0
                        ),
                    )
                    if added:
                        token_events_added += 1
                        tokens_added += total_tokens
                store.set_file_cursor(session_path, handle.tell())
        except (FileNotFoundError, PermissionError):
            continue

    return ScanResult(
        files_scanned=files_scanned,
        lines_scanned=lines_scanned,
        token_events_seen=token_events_seen,
        token_events_added=token_events_added,
        tokens_added=tokens_added,
    )
