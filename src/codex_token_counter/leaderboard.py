"""Opt-in-at-name-creation public leaderboard, independent of local counting.

Only this module knows the random per-installation credential.  It never appears
in CLI output, stream snapshots or requests to public leaderboard endpoints.
"""
from __future__ import annotations

import copy
import http.client
import ipaddress
import json
import os
import secrets
import sqlite3
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Callable


DEFAULT_SERVICE_URL = "https://zuno-leaderboard.nightmareop.chatgpt.site"
URL_OVERRIDE = "ZUNO_LEADERBOARD_URL"
SHANGHAI = timezone(timedelta(hours=8))
MAX_TOKENS = 9_007_199_254_740_991
NETWORK_TIMEOUT = 5.0
KNOWN_ERRORS = {
    "nickname_taken", "invalid_nickname", "identity_conflict", "rate_limited",
    "not_found", "unauthorized", "retired_identity", "invalid_usage",
    "invalid_request", "invalid_id", "invalid_credential", "invalid_consent",
}


class LeaderboardError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def normalize_nickname(value: str) -> str:
    name = unicodedata.normalize("NFKC", value).strip()
    if not 2 <= len(name) <= 24 or any(
        ch not in " _-" and unicodedata.category(ch)[0] not in "LN" for ch in name
    ):
        raise LeaderboardError("invalid_nickname")
    return name


def _timestamp(value: object) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp is not text")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include its timezone")
    return parsed.astimezone(timezone.utc)


def _valid_id(value: object) -> bool:
    try:
        return isinstance(value, str) and str(uuid.UUID(value, version=4)) == value
    except (ValueError, AttributeError):
        return False


def _safe_int(value: object, *, minimum: int = 0, maximum: int = MAX_TOKENS) -> bool:
    return type(value) is int and minimum <= value <= maximum


def service_url() -> str:
    value = os.environ.get(URL_OVERRIDE, DEFAULT_SERVICE_URL).strip().rstrip("/")
    if not value:
        raise LeaderboardError("not_configured")
    try:
        parsed = urllib.parse.urlsplit(value)
        parsed.port  # Validate malformed port syntax, too.
        loopback = parsed.hostname == "localhost"
        if parsed.hostname:
            try:
                loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
            except ValueError:
                pass
        if (not parsed.hostname or parsed.username or parsed.password or parsed.query
                or parsed.fragment or (parsed.scheme != "https" and not
                (parsed.scheme == "http" and loopback))):
            raise ValueError("unsafe service URL")
    except ValueError:
        raise LeaderboardError("invalid_service_url") from None
    return value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_json(method: str, path: str, *, identity: dict | None = None,
                 payload: dict | None = None, public_id: str | None = None) -> dict:
    url = service_url() + path
    headers = {"Accept": "application/json", "User-Agent": "Zuno/0.3"}
    if identity:
        headers["Authorization"] = "Bearer " + identity["credential"]
        headers["X-Zuno-ID"] = identity["id"]
    elif public_id:
        headers["X-Zuno-ID"] = public_id
    body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    if body is not None:
        if len(body) > 16 * 1024:
            raise LeaderboardError("invalid_request")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.build_opener(_NoRedirect()).open(request, timeout=NETWORK_TIMEOUT) as response:
            raw = response.read(256 * 1024 + 1)
            if len(raw) > 256 * 1024:
                raise LeaderboardError("invalid_response")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise LeaderboardError("invalid_response")
            return result
    except urllib.error.HTTPError as exc:
        try:
            error = json.loads(exc.read(4096)).get("error")
        except (ValueError, AttributeError, OSError):
            error = None
        if 300 <= exc.code < 400:
            error = "redirect_blocked"
        elif not isinstance(error, str) or error not in KNOWN_ERRORS:
            error = {401: "unauthorized", 404: "not_found", 429: "rate_limited"}.get(exc.code, "service_error")
        raise LeaderboardError(error) from None
    except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
        raise LeaderboardError("offline") from None
    except (ValueError, UnicodeError, RecursionError):
        raise LeaderboardError("invalid_response") from None


class ProfileStore:
    """Small private sidecar; the local token ledger and its baseline are untouched."""
    def __init__(self, db_path: Path):
        self.path = Path(str(db_path) + ".zuno-profile.json")
        self.lock_path = Path(str(self.path) + ".lock")

    @contextmanager
    def transaction(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(str(self.lock_path), os.O_CREAT | os.O_RDWR, 0o600)
        handle = os.fdopen(descriptor, "r+b")
        acquired = False
        try:
            if os.name != "nt":
                os.chmod(self.lock_path, 0o600)
            else:
                # msvcrt locks an existing byte; AppData inherits the user's ACL.
                if os.fstat(descriptor).st_size == 0:
                    handle.write(b"0")
                    handle.flush()
            deadline = time.monotonic() + 2
            while not acquired:
                try:
                    if os.name == "nt":
                        import msvcrt
                        handle.seek(0)
                        msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                except OSError:
                    if time.monotonic() >= deadline:
                        raise LeaderboardError("profile_busy") from None
                    time.sleep(0.02)
            state = self._read()
            original = copy.deepcopy(state)
            yield state
            if state != original:
                self._write(state)
        finally:
            if acquired:
                if os.name == "nt":
                    import msvcrt
                    handle.seek(0)
                    msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
            handle.close()

    def _read(self) -> dict:
        try:
            if self.path.stat().st_size > 8192:
                raise LeaderboardError("profile_corrupt")
            if os.name != "nt":
                os.chmod(self.path, 0o600)
            state = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (ValueError, UnicodeError, OSError):
            raise LeaderboardError("profile_corrupt") from None
        if (not isinstance(state, dict) or not _valid_id(state.get("id")) or
                not isinstance(state.get("credential"), str) or len(state["credential"]) != 64 or
                any(ch not in "0123456789abcdef" for ch in state["credential"]) or
                state.get("status") not in {"needs_name", "pending", "active", "error"}):
            raise LeaderboardError("profile_corrupt")
        if state.get("status") in {"pending", "active"}:
            try:
                if normalize_nickname(state.get("nickname", "")) != state["nickname"]:
                    raise ValueError("invalid nickname")
                if state["status"] == "active":
                    _timestamp(state["joined_at"])
            except (ValueError, KeyError, TypeError, LeaderboardError):
                raise LeaderboardError("profile_corrupt") from None
        return state

    def _write(self, state: dict) -> None:
        descriptor, temporary = tempfile.mkstemp(prefix=".zuno-profile-", dir=str(self.path.parent))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(state, handle, ensure_ascii=False, separators=(",", ":"))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def read(self) -> dict:
        with self.transaction() as state:
            return copy.deepcopy(state)


def sanitized_profile(state: dict, *, error: str | None = None) -> dict:
    return {"status": "paused" if state.get("paused") else state.get("status", "needs_name"),
            "id": state.get("id"), "nickname": state.get("nickname"),
            "joined_at": state.get("joined_at"), "error": error or state.get("error")}


def profile_status(db_path: Path) -> dict:
    try:
        return sanitized_profile(ProfileStore(db_path).read())
    except (LeaderboardError, OSError) as exc:
        return {"status": "error", "id": None, "nickname": None, "joined_at": None,
                "error": exc.code if isinstance(exc, LeaderboardError) else "profile_unavailable"}


def register_profile(db_path: Path, nickname: str, *, request: Callable = request_json) -> dict:
    store = ProfileStore(db_path)
    try:
        nickname = normalize_nickname(nickname)
    except (LeaderboardError, TypeError):
        result = profile_status(db_path)
        result["error"] = "invalid_nickname"
        return result
    try:
        with store.transaction() as state:
            if state.get("status") == "active":
                return sanitized_profile(state, error=None if nickname == state["nickname"] else "immutable_nickname")
            if state.get("status") == "pending" and state.get("nickname") != nickname:
                return sanitized_profile(state, error="registration_pending")
            if not state:
                state.update(id=str(uuid.uuid4()), credential=secrets.token_hex(32), paused=False)
            state.update(status="pending", nickname=nickname, error=None, consent_version=1)
            identity = copy.deepcopy(state)
        response = request("POST", "/api/v1/installations", identity=identity,
                           payload={"id": identity["id"], "nickname": nickname, "consent_version": 1})
        try:
            if response.get("id") != identity["id"] or response.get("nickname") != nickname:
                raise ValueError("profile mismatch")
            joined_at = _timestamp(response.get("joined_at")).isoformat()
        except (AttributeError, ValueError):
            raise LeaderboardError("invalid_response") from None
        with store.transaction() as state:
            # Another registration or a pause command may have completed meanwhile.
            if state.get("id") != identity["id"] or state.get("credential") != identity["credential"]:
                raise LeaderboardError("identity_conflict")
            state.update(status="active", nickname=nickname, joined_at=joined_at, error=None)
            return sanitized_profile(state)
    except (LeaderboardError, OSError) as exc:
        error = exc.code if isinstance(exc, LeaderboardError) else "profile_unavailable"
        try:
            with store.transaction() as state:
                if state.get("status") == "pending":
                    state["error"] = error
                    if error in {"nickname_taken", "invalid_nickname"}:
                        state.update(status="needs_name", nickname=None)
                return sanitized_profile(state, error=error)
        except (LeaderboardError, OSError):
            return {"status": "error", "id": None, "nickname": None, "joined_at": None, "error": error}


def set_paused(db_path: Path, paused: bool) -> dict:
    try:
        with ProfileStore(db_path).transaction() as state:
            if state:
                state["paused"] = bool(paused)
                state["error"] = None
            return sanitized_profile(state)
    except (LeaderboardError, OSError):
        return profile_status(db_path)


def aggregate_days(db_path: Path, joined_at: str, *, now: datetime | None = None) -> list[dict]:
    """UTC+08 event dates, never local_date or display baselines; read-only ledger."""
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    joined = _timestamp(joined_at)
    today = now.astimezone(SHANGHAI).date()
    first_day = today - timedelta(days=7)
    start = max(joined, datetime.combine(first_day, datetime.min.time(), SHANGHAI))
    totals: dict[str, int] = {}
    if not db_path.exists() or joined > now:
        return []
    connection = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
    try:
        # julianday handles offsets before filtering, unlike a lexicographic ISO comparison.
        rows = connection.execute(
            "SELECT occurred_at,total_tokens FROM usage_events "
            "WHERE event_id NOT LIKE 'simulation:%' AND session_path != 'simulation' "
            "AND julianday(occurred_at) >= julianday(?) AND julianday(occurred_at) <= julianday(?)",
            (start.isoformat(), now.isoformat()),
        )
        for occurred_at, tokens in rows:
            try:
                occurred = _timestamp(occurred_at)
            except ValueError:
                continue
            if occurred < start or occurred > now or not _safe_int(tokens):
                continue
            day = occurred.astimezone(SHANGHAI).date().isoformat()
            totals[day] = min(MAX_TOKENS, totals.get(day, 0) + tokens)
    finally:
        connection.close()
    # No synthetic zero day: a device without activity remains explicitly unranked.
    return [{"date": day, "total_tokens": total} for day, total in sorted(totals.items())]


def empty_board(status: str = "loading", *, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    return {"status": status, "date": (now.astimezone(SHANGHAI).date() - timedelta(days=1)).isoformat(),
            "time_zone": "Asia/Shanghai", "entries": [], "total_participants": 0,
            "own_entry": None, "updated_at": None, "stale": False, "offset": 0, "limit": 50}


def _entry(value: object) -> dict:
    if (not isinstance(value, dict) or not _valid_id(value.get("id")) or
            not _safe_int(value.get("rank"), minimum=1) or not _safe_int(value.get("total_tokens"))):
        raise LeaderboardError("invalid_response")
    try:
        nickname = normalize_nickname(value.get("nickname", ""))
    except (TypeError, LeaderboardError):
        raise LeaderboardError("invalid_response") from None
    return {"id": value["id"], "rank": value["rank"], "nickname": nickname,
            "total_tokens": value["total_tokens"]}


def read_leaderboard(db_path: Path, *, offset: int = 0, limit: int = 50,
                     previous: dict | None = None, request: Callable = request_json) -> dict:
    try:
        if not _safe_int(offset) or not _safe_int(limit, minimum=1, maximum=50):
            raise LeaderboardError("invalid_pagination")
        profile = profile_status(db_path)
        data = request("GET", f"/api/v1/leaderboard?offset={offset}&limit={limit}",
                       public_id=profile.get("id") if profile.get("joined_at") else None)
        if (not isinstance(data, dict) or data.get("time_zone") != "Asia/Shanghai" or
                not isinstance(data.get("entries"), list) or len(data["entries"]) > limit or
                not _safe_int(data.get("total_participants"))):
            raise LeaderboardError("invalid_response")
        date.fromisoformat(data["date"])
        _timestamp(data["updated_at"])
        result = {"status": "ok", "date": data["date"], "time_zone": "Asia/Shanghai",
                  "entries": [_entry(entry) for entry in data["entries"]],
                  "total_participants": data["total_participants"],
                  "own_entry": None if data.get("own_entry") is None else _entry(data["own_entry"]),
                  "updated_at": data["updated_at"], "stale": False, "offset": offset, "limit": limit}
        ids = [entry["id"] for entry in result["entries"]]
        if len(set(ids)) != len(ids) or any(entry["rank"] != offset + index + 1
                                          for index, entry in enumerate(result["entries"])):
            raise LeaderboardError("invalid_response")
        own = result["own_entry"]
        if ((result["entries"] and result["entries"][-1]["rank"] > result["total_participants"])
                or (own and (own["id"] != profile.get("id") or own["rank"] > result["total_participants"]))):
            raise LeaderboardError("invalid_response")
        return result
    except (LeaderboardError, ValueError, TypeError, KeyError, OSError) as exc:
        error = exc.code if isinstance(exc, LeaderboardError) else "invalid_response"
        result = copy.deepcopy(previous) if previous and previous.get("updated_at") else empty_board()
        result.update(status="not_configured" if error == "not_configured" else "offline",
                      stale=bool(result.get("updated_at")), error=error, offset=offset, limit=limit)
        return result


class LeaderboardWorker:
    """One bounded daemon, separate SQLite connections, no network on the stream thread."""
    def __init__(self, db_path: Path, *, interval: float = 300, request: Callable = request_json):
        self.db_path = db_path
        self.interval = max(1, interval)
        self.request = request
        self.changed = threading.Event()
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._snapshot = {"profile": profile_status(db_path), "leaderboard": empty_board()}
        self._thread = threading.Thread(target=self._run, name="zuno-leaderboard", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=0.1)

    def snapshot(self) -> dict:
        with self._lock:
            return copy.deepcopy(self._snapshot)

    def _publish(self, profile: dict, board: dict) -> None:
        with self._lock:
            updated = {"profile": profile, "leaderboard": board}
            if updated != self._snapshot:
                self._snapshot = copy.deepcopy(updated)
                self.changed.set()

    def _run(self) -> None:
        next_sync = 0.0
        last_identity = None
        board = empty_board()
        while not self._stop.is_set():
            profile = profile_status(self.db_path)
            identity_key = (profile["id"], profile["status"], profile.get("nickname"))
            if identity_key != last_identity:
                next_sync = 0
                last_identity = identity_key
            self._publish(profile, board)
            if time.monotonic() >= next_sync:
                next_sync = time.monotonic() + self.interval
                active_id = None
                upload_succeeded = False
                sync_error = None
                try:
                    state = ProfileStore(self.db_path).read()
                    if state.get("status") == "pending" and not state.get("paused"):
                        register_profile(self.db_path, state["nickname"], request=self.request)
                    state = ProfileStore(self.db_path).read()
                    if state.get("status") == "active" and not state.get("paused") and not self._stop.is_set():
                        active_id = state["id"]
                        days = aggregate_days(self.db_path, state["joined_at"])
                        # Re-check pause after aggregation before commencing any upload.
                        latest = ProfileStore(self.db_path).read()
                        if days and not latest.get("paused") and latest.get("id") == state["id"]:
                            self.request("POST", "/api/v1/usage", identity=state, payload={"days": days})
                            upload_succeeded = True
                except (LeaderboardError, OSError, sqlite3.Error, ValueError, KeyError) as exc:
                    # Do not let credential-bearing exception text reach stream/UI logs.
                    if active_id:
                        allowed = KNOWN_ERRORS | {"offline", "not_configured", "invalid_service_url",
                                                  "redirect_blocked", "invalid_response", "service_error"}
                        sync_error = exc.code if isinstance(exc, LeaderboardError) and exc.code in allowed else "usage_unavailable"
                if active_id and (sync_error or upload_succeeded):
                    try:
                        with ProfileStore(self.db_path).transaction() as current:
                            if current.get("id") == active_id and current.get("status") == "active" and not current.get("paused"):
                                # A public GET is not proof that private usage sync succeeded.
                                # No pending data and pausing also must not clear an upload failure.
                                current["error"] = sync_error
                    except (LeaderboardError, OSError):
                        pass
                if self._stop.is_set():
                    break
                board = read_leaderboard(self.db_path, previous=board, request=self.request)
                current_profile = profile_status(self.db_path)
                board["own_entry_stale"] = current_profile["status"] == "paused" or bool(current_profile.get("error"))
                if current_profile["status"] == "active" and current_profile.get("error"):
                    board["error"] = "sync_failed"
                self._publish(current_profile, board)
            self._stop.wait(1)
