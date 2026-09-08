"""Read Codex's account weekly quota, keeping observed manual resets locally.

This percentage is the service's quota percentage, not a conversion of tokens.
Only read-only app-server account requests are made. No login, reset redemption,
or inference is performed by this module.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import queue
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol


WEEK_MINUTES = 7 * 24 * 60
STATE_KEY = "weekly_quota_v1"
CLI_OVERRIDE = "CODEX_TOKEN_OBSERVER_CODEX_BIN"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
PIPE_POLL_SECONDS = 0.05


class MetadataStore(Protocol):
    def get_metadata(self, key: str) -> str | None: ...
    def set_metadata(self, key: str, value: str) -> None: ...


class QuotaUnavailable(Exception):
    """A safe, non-sensitive status code for an unavailable account reading."""


def _codex_binary() -> str:
    override = os.environ.get(CLI_OVERRIDE)
    windows = sys.platform == "win32"
    if override:
        # An explicit override is authoritative; do not silently select another
        # account's installation, or send a .cmd/.bat through a command shell.
        candidates = [override]
    elif windows:
        candidates = [shutil.which("codex.exe")]
        wrapper = shutil.which("codex.cmd") or shutil.which("codex")
        if wrapper:
            candidates.extend(_windows_npm_binaries(Path(wrapper)))
    else:
        candidates = [shutil.which("codex")]
        if sys.platform == "darwin":
            candidates.extend([
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
            ])
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if (not windows or path.suffix.lower() == ".exe") and path.is_file() and os.access(path, os.X_OK):
                return str(path)
    raise QuotaUnavailable("cli_unavailable")


def _windows_npm_binaries(wrapper: Path) -> list[Path]:
    """Resolve a found npm wrapper's native package without executing the wrapper.

    Codex's official npm launcher defines the platform packages and vendor/bin
    layout; older versions used vendor/<target>/codex instead. Only adjacent npm
    package roots are inspected, never guessed Windows Store installation paths.
    """
    if wrapper.suffix.lower() not in {".cmd", ".bat", ""}:
        return []
    machine = platform.machine().lower()
    if machine in {"amd64", "x86_64"}:
        target, package = "x86_64-pc-windows-msvc", "codex-win32-x64"
    elif machine in {"arm64", "aarch64"}:
        target, package = "aarch64-pc-windows-msvc", "codex-win32-arm64"
    else:
        return []
    modules = wrapper.parent / "node_modules"
    if wrapper.parent.name == ".bin":
        modules = wrapper.parent.parent
    codex_package = modules / "@openai" / "codex"
    vendor_roots = [
        codex_package / "node_modules" / "@openai" / package / "vendor",
        modules / "@openai" / package / "vendor",
        codex_package / "vendor",
    ]
    return [root / target / subdir / "codex.exe"
            for root in vendor_roots for subdir in ("bin", "codex")]


def _stdout_reader(pipe: Any, chunks: queue.Queue, stopped: threading.Event) -> None:
    """Read small chunks into a bounded queue, with interruptible pipe waiting.

    Windows selectors only support sockets. PeekNamedPipe works on subprocess
    anonymous pipes and lets this worker check cancellation without blocking in
    ReadFile. POSIX select is used only on POSIX, with the same bounded wait.
    Neither branch leaves a blocked reader if a descendant retains stdout.
    """
    def publish(data: bytes) -> None:
        while not stopped.is_set():
            try:
                chunks.put(data, timeout=PIPE_POLL_SECONDS)
                return
            except queue.Full:
                continue

    try:
        descriptor = pipe.fileno()
        if sys.platform == "win32":
            import ctypes
            import msvcrt
            from ctypes import wintypes

            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            peek = kernel.PeekNamedPipe
            peek.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                             ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD),
                             ctypes.POINTER(wintypes.DWORD)]
            peek.restype = wintypes.BOOL
            handle = msvcrt.get_osfhandle(descriptor)
            while not stopped.is_set():
                available = wintypes.DWORD()
                if not peek(handle, None, 0, None, ctypes.byref(available), None):
                    publish(b"")
                    return
                if not available.value:
                    stopped.wait(PIPE_POLL_SECONDS)
                    continue
                data = os.read(descriptor, min(65536, available.value))
                publish(data)
                if not data:
                    return
        else:
            import select

            while not stopped.is_set():
                readable, _, _ = select.select([descriptor], [], [], PIPE_POLL_SECONDS)
                if not readable:
                    continue
                data = os.read(descriptor, 65536)
                publish(data)
                if not data:
                    return
    except (OSError, ValueError):
        publish(b"")


def _read_account_snapshot(timeout: float = 12.0) -> tuple[dict, dict]:
    """Perform the documented JSONL handshake and two read-only account calls.

    Keep account details in memory only; callers persist a hashed identity. A
    single deadline bounds initialization and both requests, including servers
    that write incomplete JSONL lines or unrelated notifications.
    """
    try:
        process = subprocess.Popen(
            [_codex_binary(), "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            **({"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}),
        )
    except OSError as error:
        raise QuotaUnavailable("cli_unavailable") from error
    assert process.stdin is not None and process.stdout is not None
    deadline = time.monotonic() + timeout
    buffer = bytearray()
    chunks: queue.Queue = queue.Queue(maxsize=4)
    stopped = threading.Event()
    reader = threading.Thread(target=_stdout_reader, args=(process.stdout, chunks, stopped),
                              name="codex-quota-stdout")
    reader.start()
    received = 0

    def send(message: dict) -> None:
        try:
            process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            process.stdin.flush()
        except (OSError, ValueError) as error:
            raise QuotaUnavailable("connection_closed") from error

    def request(request_id: int, method: str, params: dict) -> dict:
        nonlocal received
        send({"id": request_id, "method": method, "params": params})
        while True:
            while b"\n" in buffer:
                if time.monotonic() >= deadline:
                    raise QuotaUnavailable("timeout")
                line, _, remainder = buffer.partition(b"\n")
                buffer[:] = remainder
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if not isinstance(message, dict) or message.get("id") != request_id:
                    continue
                if "error" in message or not isinstance(message.get("result"), dict):
                    raise QuotaUnavailable("account_read_failed")
                return message["result"]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise QuotaUnavailable("timeout")
            try:
                data = chunks.get(timeout=remaining)
            except queue.Empty as error:
                raise QuotaUnavailable("timeout") from error
            if not data:
                raise QuotaUnavailable("connection_closed")
            received += len(data)
            if received > MAX_RESPONSE_BYTES:
                raise QuotaUnavailable("invalid_response")
            buffer.extend(data)

    try:
        request(1, "initialize", {"clientInfo": {
            "name": "codex_token_observer",
            "title": "Zuno",
            "version": "0.3.0",
        }})
        send({"method": "initialized"})
        account_result = request(2, "account/read", {"refreshToken": False})
        limits_result = request(3, "account/rateLimits/read", {})
        return account_result, limits_result
    except OSError as error:
        raise QuotaUnavailable("connection_closed") from error
    finally:
        stopped.set()
        # Join before closing the file object. Pipe readiness and queue writes
        # both check stopped, so this cannot wait for an uncooperative server.
        reader.join()
        try:
            if process.poll() is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1.0)
        finally:
            process.stdin.close()
            process.stdout.close()


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except (OverflowError, ValueError):
        return None
    return number if math.isfinite(number) and number >= 0 else None


def select_weekly_window(limits: dict) -> dict | None:
    """Find the main Codex weekly window, independent of primary/secondary order.

    A supplied per-limit map is authoritative, including a missing Codex entry.
    Spark or any future specialized bucket must not masquerade as main quota.
    """
    buckets = limits.get("rateLimitsByLimitId")
    if isinstance(buckets, dict):
        bucket = buckets.get("codex")
    else:
        bucket = limits.get("rateLimits")
        if isinstance(bucket, dict) and bucket.get("limitId") not in (None, "codex"):
            return None
    if not isinstance(bucket, dict):
        return None
    for name in ("primary", "secondary"):
        window = bucket.get(name)
        if not isinstance(window, dict) or window.get("windowDurationMins") != WEEK_MINUTES:
            continue
        used = _number(window.get("usedPercent"))
        resets = _number(window.get("resetsAt"))
        if used is None or resets is None or resets == 0:
            continue
        return {"used_percent": used, "resets_at": int(resets)}
    return None


def _account_key(account_result: dict, limits: dict) -> str | None:
    identity = limits.get("accountId")
    if not isinstance(identity, str) or not identity:
        account = account_result.get("account")
        if not isinstance(account, dict) or account.get("type") != "chatgpt":
            return None
        identity = account.get("id") or account.get("email")
        if not isinstance(identity, str) or not identity:
            return None
        identity = "chatgpt:" + identity.strip().lower()
    else:
        identity = "account:" + identity
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _load_state(store: MetadataStore) -> dict:
    try:
        value = json.loads(store.get_metadata(STATE_KEY) or "{}")
    except (TypeError, ValueError):
        value = {}
    if not isinstance(value, dict) or not isinstance(value.get("accounts"), dict):
        return {"accounts": {}, "active": None}
    return value


def _result(record: dict | None, *, stale: bool, status: str) -> dict:
    record = record or {}
    current = _number(record.get("current_percent"))
    carry = _number(record.get("carry_percent")) or 0.0
    return {
        "available": current is not None,
        "status": status,
        "current_percent": current,
        "cumulative_percent": None if current is None else round(carry + current, 4),
        "resets_at": record.get("resets_at"),
        "observed_at": record.get("observed_at"),
        "reset_count": record.get("reset_count", 0),
        "stale": stale,
        "estimated": bool(record.get("estimated", False)),
        "window_minutes": WEEK_MINUTES,
    }


def _reset_credits(limits: dict) -> int | None:
    credits = limits.get("rateLimitResetCredits")
    count = _number(credits.get("availableCount")) if isinstance(credits, dict) else None
    return int(count) if count is not None and count.is_integer() else None


def poll_weekly_quota(store: MetadataStore, now: datetime | None = None) -> dict:
    """Return weekly quota with reset carry; unavailable values remain ``None``.

    The first sample starts at the account's currently reported percentage.
    Observed early resets carry the previous segment's highest observed usage,
    not an assumed 100%. Such accumulated readings are marked estimated because
    usage immediately before the reset can be missed between polls. A natural
    weekly rollover clears carry. Each account has an isolated persisted record.

    On failures a prior reading is returned as stale with its original timestamp;
    callers should continue local token collection and retry on their own cadence.
    """
    state = _load_state(store)
    accounts = state["accounts"]
    previous = accounts.get(state.get("active"))
    if not isinstance(previous, dict):
        previous = None
    try:
        account_result, limits = _read_account_snapshot()
    except QuotaUnavailable as error:
        return _result(previous, stale=True, status=str(error))
    identity = _account_key(account_result, limits)
    if identity is None:
        # No identity means we cannot safely attribute even a valid window.
        if state.get("active") is not None:
            state["active"] = None
            store.set_metadata(STATE_KEY, json.dumps(state, separators=(",", ":")))
        return _result(None, stale=True, status="account_unavailable")
    previous = accounts.get(identity)
    if not isinstance(previous, dict):
        previous = None
    # Persist an identified account switch even if its quota is unavailable, so a
    # subsequent outage cannot display another account's cached percentage.
    if state.get("active") != identity:
        state["active"] = identity
        store.set_metadata(STATE_KEY, json.dumps(state, separators=(",", ":")))
    window = select_weekly_window(limits)
    if window is None:
        return _result(previous, stale=True, status="weekly_unavailable")
    moment = now or datetime.now(timezone.utc)
    timestamp = moment.timestamp()
    if window["resets_at"] <= timestamp:
        return _result(previous, stale=True, status="expired_reading")

    used = window["used_percent"]
    resets_at = window["resets_at"]
    credits = _reset_credits(limits)
    carry = 0.0
    reset_count = 0
    segment_peak = used
    estimated = False
    if previous is not None:
        old_used = _number(previous.get("current_percent"))
        old_resets = _number(previous.get("resets_at"))
        old_peak = _number(previous.get("segment_peak"))
        if old_used is not None and old_resets is not None:
            natural_rollover = timestamp >= old_resets and resets_at != old_resets
            if not natural_rollover:
                carry = _number(previous.get("carry_percent")) or 0.0
                reset_count = int(_number(previous.get("reset_count")) or 0)
                estimated = bool(previous.get("estimated", False))
                old_credits = _number(previous.get("reset_credits"))
                credit_spent = credits is not None and old_credits is not None and credits < old_credits
                dropped = used < old_used
                deadline_moved = resets_at > old_resets + 60
                # A small correction in the same window is not reset evidence.
                # Credit expiry alone is also insufficient: a drop or shifted
                # deadline is needed, while an early shifted deadline + drop can
                # identify a reset on servers that omit reset-credit information.
                manual_reset = timestamp < old_resets and (
                    (credit_spent and (dropped or deadline_moved))
                    or (deadline_moved and dropped)
                )
                if manual_reset:
                    carry += max(old_peak or 0.0, old_used)
                    reset_count += 1
                    estimated = True
                else:
                    segment_peak = max(old_peak or 0.0, used)
    record = {
        "current_percent": used,
        "carry_percent": carry,
        "segment_peak": segment_peak,
        "resets_at": resets_at,
        "observed_at": moment.astimezone(timezone.utc).isoformat(),
        "reset_credits": credits,
        "reset_count": reset_count,
        "estimated": estimated,
    }
    accounts[identity] = record
    state["active"] = identity
    store.set_metadata(STATE_KEY, json.dumps(state, separators=(",", ":")))
    return _result(record, stale=False, status="ok")
