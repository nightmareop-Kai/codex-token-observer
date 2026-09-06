from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from codex_token_counter.quota import (
    STATE_KEY,
    CLI_OVERRIDE,
    QuotaUnavailable,
    _codex_binary,
    _read_account_snapshot,
    poll_weekly_quota,
    select_weekly_window,
)


class MemoryStore:
    def __init__(self) -> None:
        self.metadata: dict[str, str] = {}

    def get_metadata(self, key: str) -> str | None:
        return self.metadata.get(key)

    def set_metadata(self, key: str, value: str) -> None:
        self.metadata[key] = value


class QuotaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store = MemoryStore()
        self.now = datetime(2026, 9, 6, 12, tzinfo=timezone.utc)
        self.deadline = int((self.now + timedelta(days=5)).timestamp())

    def limits(self, used=46, deadline=None, credits=2, account="account-a") -> dict:
        return {
            "accountId": account,
            "rateLimitsByLimitId": {"codex": {
                "primary": {
                    "usedPercent": used,
                    "windowDurationMins": 10080,
                    "resetsAt": deadline or self.deadline,
                },
                "secondary": None,
            }},
            "rateLimitResetCredits": {"availableCount": credits},
        }

    def poll(self, payload, now=None):
        with patch("codex_token_counter.quota._read_account_snapshot", return_value=({}, payload)):
            return poll_weekly_quota(self.store, now=now or self.now)

    @contextmanager
    def fake_server(self, script):
        """Real child pipes on each OS; never require a shell or Unix shebang."""
        original_popen = subprocess.Popen
        children = []
        existing_readers = {thread.ident for thread in threading.enumerate()
                            if thread.name == "codex-quota-stdout"}

        def start_fake(command, **kwargs):
            self.assertEqual(command, ["/fake/codex", "app-server"])
            self.assertNotIn("shell", kwargs)
            child = original_popen([sys.executable, "-u", "-c", script], **kwargs)
            children.append(child)
            return child

        with patch("codex_token_counter.quota._codex_binary", return_value="/fake/codex"), patch(
            "codex_token_counter.quota.subprocess.Popen", side_effect=start_fake
        ):
            try:
                yield children
            finally:
                self.assertTrue(children)
                for child in children:
                    self.assertIsNotNone(child.poll())
                    self.assertTrue(child.stdin.closed)
                    self.assertTrue(child.stdout.closed)
                remaining_readers = {thread.ident for thread in threading.enumerate()
                                     if thread.name == "codex-quota-stdout"}
                self.assertEqual(remaining_readers, existing_readers)

    def test_weekly_primary_or_secondary_and_never_spark(self):
        data = self.limits()
        self.assertEqual(select_weekly_window(data)["used_percent"], 46)
        bucket = data["rateLimitsByLimitId"]["codex"]
        bucket["secondary"] = bucket["primary"]
        bucket["primary"] = {"usedPercent": 90, "windowDurationMins": 300, "resetsAt": self.deadline}
        self.assertEqual(select_weekly_window(data)["used_percent"], 46)
        data["rateLimitsByLimitId"]["codex_bengalfox"] = data["rateLimitsByLimitId"].pop("codex")
        self.assertIsNone(select_weekly_window(data))
        data["rateLimits"] = {"limitId": "codex", **bucket}
        self.assertIsNone(select_weekly_window(data))
        del data["rateLimitsByLimitId"]
        self.assertEqual(select_weekly_window(data)["used_percent"], 46)

    def test_initial_sample_has_no_invented_history(self):
        result = self.poll(self.limits(46))
        self.assertEqual(result["cumulative_percent"], 46)
        self.assertEqual(result["reset_count"], 0)
        self.assertFalse(result["estimated"])
        self.assertFalse(result["stale"])
        self.assertNotIn("account-a", self.store.get_metadata(STATE_KEY))

    def test_manual_reset_accumulates_over_100_and_survives_restart(self):
        self.poll(self.limits(98))
        shifted = self.deadline + 2 * 86400
        reset = self.poll(self.limits(0, shifted, credits=1), self.now + timedelta(minutes=1))
        self.assertEqual(reset["cumulative_percent"], 98)
        # Simulate process restart using only persisted JSON, not module globals.
        new_store = MemoryStore()
        new_store.metadata = dict(self.store.metadata)
        self.store = new_store
        result = self.poll(self.limits(20, shifted, credits=1), self.now + timedelta(minutes=2))
        self.assertEqual(result["current_percent"], 20)
        self.assertEqual(result["cumulative_percent"], 118)
        self.assertEqual(result["reset_count"], 1)
        self.assertTrue(result["estimated"])

    def test_reset_carries_observed_peak_not_assumed_full_quota(self):
        self.poll(self.limits(70))
        self.poll(self.limits(69))  # Service correction must not become a reset.
        result = self.poll(self.limits(10, self.deadline + 3600, credits=1))
        self.assertEqual(result["cumulative_percent"], 80)
        self.assertEqual(result["reset_count"], 1)

    def test_early_deadline_and_drop_can_detect_reset_without_credits(self):
        self.poll(self.limits(85, credits=None))
        result = self.poll(self.limits(3, self.deadline + 3600, credits=None))
        self.assertEqual(result["cumulative_percent"], 88)
        self.assertTrue(result["estimated"])

    def test_natural_rollover_clears_carry(self):
        self.poll(self.limits(98))
        shifted = self.deadline + 3600
        self.poll(self.limits(20, shifted, credits=1))
        next_week = datetime.fromtimestamp(shifted + 60, timezone.utc)
        result = self.poll(self.limits(2, shifted + 7 * 86400, credits=1), next_week)
        self.assertEqual(result["cumulative_percent"], 2)
        self.assertEqual(result["reset_count"], 0)
        self.assertFalse(result["estimated"])

    def test_same_window_corrections_and_credit_expiry_do_not_reset(self):
        self.poll(self.limits(70))
        corrected = self.poll(self.limits(68))
        self.assertEqual(corrected["cumulative_percent"], 68)
        self.assertEqual(corrected["reset_count"], 0)
        expired_credit = self.poll(self.limits(72, credits=1))
        self.assertEqual(expired_credit["cumulative_percent"], 72)
        self.assertEqual(expired_credit["reset_count"], 0)

    def test_missing_values_are_not_zero_and_stale_keeps_timestamp(self):
        missing = self.poll(self.limits(None))
        self.assertIsNone(missing["current_percent"])
        self.assertFalse(missing["available"])
        good = self.poll(self.limits(46))
        late = self.now + timedelta(minutes=2)
        missing = self.poll(self.limits(None), late)
        self.assertEqual(missing["cumulative_percent"], 46)
        self.assertEqual(missing["observed_at"], good["observed_at"])
        self.assertTrue(missing["stale"])
        with patch("codex_token_counter.quota._read_account_snapshot", side_effect=QuotaUnavailable("timeout")):
            result = poll_weekly_quota(self.store, now=late)
        self.assertEqual(result["cumulative_percent"], 46)
        self.assertEqual(result["observed_at"], good["observed_at"])
        self.assertEqual(result["status"], "timeout")

    def test_account_switch_isolates_carry_and_unavailable_state(self):
        self.poll(self.limits(98))
        self.poll(self.limits(20, self.deadline + 3600, credits=1))
        result = self.poll(self.limits(8, account="account-b"))
        self.assertEqual(result["cumulative_percent"], 8)
        self.assertEqual(result["reset_count"], 0)
        result = self.poll(self.limits(22, self.deadline + 3600, credits=1))
        self.assertEqual(result["cumulative_percent"], 120)
        unknown = self.poll(self.limits(None, account="account-c"))
        self.assertFalse(unknown["available"])
        with patch("codex_token_counter.quota._read_account_snapshot", side_effect=QuotaUnavailable("timeout")):
            unknown = poll_weekly_quota(self.store, now=self.now)
        self.assertFalse(unknown["available"])

    def test_expired_server_snapshot_is_stale_without_overwriting_reading(self):
        old = self.poll(self.limits(46))
        now = datetime.fromtimestamp(self.deadline + 60, timezone.utc)
        result = self.poll(self.limits(46), now)
        self.assertEqual(result["status"], "expired_reading")
        self.assertEqual(result["observed_at"], old["observed_at"])
        self.assertTrue(result["stale"])

    def test_missing_account_does_not_reattach_old_account_on_outage(self):
        self.poll(self.limits(46))
        payload = self.limits(47)
        del payload["accountId"]
        result = self.poll(payload)
        self.assertFalse(result["available"])
        with patch("codex_token_counter.quota._read_account_snapshot", side_effect=QuotaUnavailable("timeout")):
            result = poll_weekly_quota(self.store, now=self.now)
        self.assertFalse(result["available"])

    def test_account_email_fallback_is_hashed(self):
        limits = self.limits(12)
        del limits["accountId"]
        account = {"account": {"type": "chatgpt", "email": "friend@example.com"}}
        with patch("codex_token_counter.quota._read_account_snapshot", return_value=(account, limits)):
            result = poll_weekly_quota(self.store, now=self.now)
        self.assertEqual(result["cumulative_percent"], 12)
        persisted = self.store.get_metadata(STATE_KEY)
        self.assertNotIn("friend@example.com", persisted)
        self.assertEqual(len(json.loads(persisted)["active"]), 64)

    def test_app_server_handshake_is_read_only_and_child_is_reaped(self):
        script = r'''
import json, sys
expected = ["initialize", "initialized", "account/read", "account/rateLimits/read"]
for raw in sys.stdin:
    message = json.loads(raw)
    method = message["method"]
    assert expected and method == expected.pop(0)
    if method == "initialized":
        continue
    if method == "initialize":
        assert message["params"]["clientInfo"]["name"] == "codex_token_observer"
        result = {"userAgent": "test"}
        print(json.dumps({"method": "unrelated/notification", "params": {}}), flush=True)
    elif method == "account/read":
        assert message["params"] == {"refreshToken": False}
        result = {"account": {"type": "chatgpt", "email": "test@example.com"}}
    else:
        assert message["params"] == {}
        result = {"accountId": "test-account", "rateLimitsByLimitId": {}}
    line = json.dumps({"id": message["id"], "result": result}) + "\n"
    sys.stdout.write(line[:4]); sys.stdout.flush()
    sys.stdout.write(line[4:]); sys.stdout.flush()
'''
        with self.fake_server(script):
            account, limits = _read_account_snapshot(timeout=2)
        self.assertEqual(limits["accountId"], "test-account")
        self.assertEqual(account["account"]["type"], "chatgpt")

    def test_incomplete_jsonl_times_out_and_child_is_reaped(self):
        script = 'import sys,time; sys.stdout.write("{"); sys.stdout.flush(); time.sleep(30)'
        with self.fake_server(script):
            with self.assertRaisesRegex(QuotaUnavailable, "timeout"):
                _read_account_snapshot(timeout=0.1)

    def test_eof_is_unavailable_and_reader_and_child_are_reaped(self):
        with self.fake_server('import sys; sys.stdin.readline()'):
            with self.assertRaisesRegex(QuotaUnavailable, "connection_closed"):
                _read_account_snapshot(timeout=2)

    def test_oversized_output_is_bounded_and_reader_and_child_are_reaped(self):
        script = 'import sys,time; sys.stdout.buffer.write(b"x" * (3 * 1024 * 1024)); sys.stdout.flush(); time.sleep(30)'
        with self.fake_server(script):
            with self.assertRaisesRegex(QuotaUnavailable, "invalid_response"):
                _read_account_snapshot(timeout=2)

    def test_timeout_uses_one_deadline_across_requests(self):
        script = r'''
import json, sys, time
for raw in sys.stdin:
    message = json.loads(raw)
    if "id" not in message:
        continue
    time.sleep(0.25)
    print(json.dumps({"id": message["id"], "result": {}}), flush=True)
'''
        started = time.monotonic()
        with self.fake_server(script):
            with self.assertRaisesRegex(QuotaUnavailable, "timeout"):
                _read_account_snapshot(timeout=0.55)
        self.assertLess(time.monotonic() - started, 1.5)

    def test_notification_flood_obeys_deadline_and_releases_full_queue(self):
        script = r'''
import sys
line = b'{"method":"unrelated"}\n'
while True:
    sys.stdout.buffer.write(line * 1000)
    sys.stdout.buffer.flush()
'''
        with self.fake_server(script):
            with self.assertRaisesRegex(QuotaUnavailable, "timeout|invalid_response"):
                _read_account_snapshot(timeout=0.15)

    def test_windows_explicit_exe_override_is_authoritative(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / "codex.exe"
            executable.write_bytes(b"fixture, never executed")
            executable.chmod(0o755)
            with patch("codex_token_counter.quota.sys.platform", "win32"), patch.dict(
                os.environ, {CLI_OVERRIDE: str(executable)}, clear=True
            ), patch("codex_token_counter.quota.shutil.which") as which:
                self.assertEqual(_codex_binary(), str(executable))
                which.assert_not_called()

    def test_windows_wrapper_override_is_not_executed_or_silently_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            wrapper = Path(folder) / "codex.cmd"
            wrapper.write_bytes(b"fixture, never executed")
            wrapper.chmod(0o755)
            with patch("codex_token_counter.quota.sys.platform", "win32"), patch.dict(
                os.environ, {CLI_OVERRIDE: str(wrapper)}, clear=True
            ), patch("codex_token_counter.quota.shutil.which") as which:
                with self.assertRaisesRegex(QuotaUnavailable, "cli_unavailable"):
                    _codex_binary()
                which.assert_not_called()

    def test_windows_path_prefers_native_exe(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / "codex.exe"
            executable.write_bytes(b"fixture, never executed")
            executable.chmod(0o755)
            with patch("codex_token_counter.quota.sys.platform", "win32"), patch.dict(
                os.environ, {}, clear=True
            ), patch("codex_token_counter.quota.shutil.which",
                     side_effect=lambda name: str(executable) if name == "codex.exe" else None):
                self.assertEqual(_codex_binary(), str(executable))

    def test_windows_npm_wrapper_resolves_existing_native_vendor_binary(self):
        layouts = [
            ("codex", "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"),
            ("codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "bin", "codex.exe"),
            ("codex", "node_modules", "@openai", "codex-win32-x64", "vendor",
             "x86_64-pc-windows-msvc", "bin", "codex.exe"),
        ]
        for layout in layouts:
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                wrapper = root / "codex.cmd"
                wrapper.write_bytes(b"fixture, never executed")
                native = root / "node_modules" / "@openai"
                native = native.joinpath(*layout)
                native.parent.mkdir(parents=True)
                native.write_bytes(b"fixture, never executed")
                native.chmod(0o755)
                with patch("codex_token_counter.quota.sys.platform", "win32"), patch.dict(
                    os.environ, {}, clear=True
                ), patch("codex_token_counter.quota.platform.machine", return_value="AMD64"), patch(
                    "codex_token_counter.quota.shutil.which",
                    side_effect=lambda name: str(wrapper) if name == "codex.cmd" else None
                ):
                    self.assertEqual(_codex_binary(), str(native))

    def test_windows_missing_native_cli_is_unavailable(self):
        with tempfile.TemporaryDirectory() as folder:
            wrapper = Path(folder) / "codex.cmd"
            wrapper.write_bytes(b"fixture, never executed")
            with patch("codex_token_counter.quota.sys.platform", "win32"), patch.dict(
                os.environ, {}, clear=True
            ), patch("codex_token_counter.quota.platform.machine", return_value="AMD64"), patch(
                "codex_token_counter.quota.shutil.which",
                side_effect=lambda name: str(wrapper) if name == "codex.cmd" else None
            ):
                with self.assertRaisesRegex(QuotaUnavailable, "cli_unavailable"):
                    _codex_binary()


if __name__ == "__main__":
    unittest.main()
