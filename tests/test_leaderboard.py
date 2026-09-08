from __future__ import annotations

import io
import json
import os
import queue
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from codex_token_counter.leaderboard import (
    LeaderboardError, LeaderboardWorker, ProfileStore, SHANGHAI, URL_OVERRIDE,
    aggregate_days, empty_board, normalize_nickname, profile_status,
    read_leaderboard, register_profile, request_json, service_url, set_paused,
)
from codex_token_counter.storage import TokenStore


class FakeService:
    def __init__(self, joined="2026-09-08T00:00:00Z"):
        self.joined = joined
        self.profiles = {}
        self.days = {}
        self.calls = []
        self.fail = None
        self.lock = threading.Lock()

    def request(self, method, path, **kwargs):
        with self.lock:
            self.calls.append((method, path, kwargs))
            if self.fail:
                raise LeaderboardError(self.fail)
            identity = kwargs.get("identity", {})
            payload = kwargs.get("payload", {})
            if path == "/api/v1/installations":
                found = self.profiles.get(identity["id"])
                if found:
                    return dict(found)
                # Match the server's NFKC + lowercase key, not Unicode casefold.
                name = normalize_nickname(payload["nickname"])
                if any(normalize_nickname(item["nickname"]).lower() == name.lower()
                       for item in self.profiles.values()):
                    raise LeaderboardError("nickname_taken")
                result = {"id": identity["id"], "nickname": name, "joined_at": self.joined}
                self.profiles[identity["id"]] = result
                return dict(result)
            if path == "/api/v1/usage":
                for day in payload["days"]:
                    key = (identity["id"], day["date"])
                    self.days[key] = max(self.days.get(key, 0), day["total_tokens"])
                return {"ok": True}
            return {"date": "2026-09-07", "time_zone": "Asia/Shanghai", "entries": [],
                    "total_participants": 0, "own_entry": None, "updated_at": "2026-09-08T00:00:00Z"}


@contextmanager
def http_service(callback):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            callback(self)

        do_POST = do_GET

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


class LeaderboardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.db = Path(self.temporary.name) / "ledger.sqlite3"
        self.store = TokenStore(self.db)
        self.addCleanup(self.store.close)
        self.api = FakeService()

    def join(self, name="小庄 Zuno"):
        return register_profile(self.db, name, request=self.api.request)

    def event(self, name, at, tokens=100, session="real-session"):
        self.store.add_usage_event(event_id=name, occurred_at=datetime.fromisoformat(at),
                                   total_tokens=tokens, session_path=session, byte_offset=0)

    def wait_until(self, check, timeout=3):
        deadline = time.monotonic() + timeout
        while not check():
            if time.monotonic() > deadline:
                self.fail("timed out waiting for worker")
            time.sleep(0.02)

    def test_normalization_and_reject_markup_bidi_controls(self):
        self.assertEqual(normalize_nickname("  Ｚｕｎｏ 小庄  "), "Zuno 小庄")
        for name in ["A", "A" * 25, "a<b", "a\u202eb", "a\nb", "a/b", "🐈猫"]:
            with self.subTest(name=name), self.assertRaises(LeaderboardError):
                normalize_nickname(name)

    def test_first_status_has_no_identity_or_upload(self):
        self.assertEqual(profile_status(self.db)["status"], "needs_name")
        self.assertFalse(ProfileStore(self.db).path.exists())
        self.assertEqual(self.api.calls, [])

    def test_registration_restart_and_immutable_nickname(self):
        profile = self.join()
        self.assertEqual(profile["status"], "active")
        self.assertEqual(profile["nickname"], "小庄 Zuno")
        state = ProfileStore(self.db).read()
        self.assertNotIn(state["credential"], json.dumps(profile))
        self.assertEqual(len(state["credential"]), 64)
        self.assertEqual(profile_status(self.db), profile)
        self.assertEqual(self.join()["id"], profile["id"])
        self.assertEqual(self.join("Different")["error"], "immutable_nickname")
        self.assertEqual(len(self.api.calls), 1)
        if os.name != "nt":
            self.assertEqual(ProfileStore(self.db).path.stat().st_mode & 0o777, 0o600)

    def test_identity_is_durable_before_first_network_request(self):
        def checking_request(method, path, **kwargs):
            state = ProfileStore(self.db).read()
            self.assertEqual(state["credential"], kwargs["identity"]["credential"])
            self.assertEqual(state["status"], "pending")
            self.assertEqual(set(kwargs["payload"]), {"id", "nickname", "consent_version"})
            return self.api.request(method, path, **kwargs)
        self.assertEqual(register_profile(self.db, "Durable", request=checking_request)["status"], "active")

    def test_two_installations_have_distinct_random_ids_and_unique_names(self):
        one = self.join()
        other_db = self.db.parent / "other.sqlite3"
        failed = register_profile(other_db, "小庄 Zuno", request=self.api.request)
        self.assertEqual(failed["error"], "nickname_taken")
        self.assertEqual(failed["status"], "needs_name")
        two = register_profile(other_db, "Other Zuno", request=self.api.request)
        self.assertEqual(two["status"], "active")
        self.assertNotEqual(one["id"], two["id"])
        self.assertEqual(failed["id"], two["id"])

    def test_unicode_name_uniqueness_uses_nfkc_and_lowercase_not_casefold(self):
        cases = [
            ("ＭÜＮＣＨＥＮ", "München", True),
            ("Straße", "STRAẞE", True),
            ("Straße", "STRASSE", False),
            ("ΟΣ", "Ος", True),
            ("ΟΣ", "οσ", False),
        ]
        for index, (first_name, second_name, collides) in enumerate(cases):
            with self.subTest(first=first_name, second=second_name):
                service = FakeService()
                first_db = self.db.parent / f"unicode-{index}-a.sqlite3"
                second_db = self.db.parent / f"unicode-{index}-b.sqlite3"
                first = register_profile(first_db, first_name, request=service.request)
                second = register_profile(second_db, second_name, request=service.request)
                self.assertEqual(first["status"], "active")
                self.assertEqual(first["nickname"], normalize_nickname(first_name))
                if collides:
                    self.assertEqual(second["error"], "nickname_taken")
                    self.assertEqual(second["status"], "needs_name")
                else:
                    self.assertEqual(second["status"], "active")
                    self.assertNotEqual(first["id"], second["id"])

    def test_unknown_outcome_retry_keeps_same_name_and_identity(self):
        def lost_response(*args, **kwargs):
            self.api.request(*args, **kwargs)
            raise LeaderboardError("offline")

        first = register_profile(self.db, "Permanent", request=lost_response)
        self.assertEqual(first["status"], "pending")
        credential = ProfileStore(self.db).read()["credential"]
        self.assertEqual(self.join("Other")["error"], "registration_pending")
        self.assertEqual(self.join("<bad>")["error"], "invalid_nickname")
        self.assertEqual(profile_status(self.db)["nickname"], "Permanent")
        final = self.join("Permanent")
        self.assertEqual(final["status"], "active")
        self.assertEqual(final["id"], first["id"])
        self.assertEqual(ProfileStore(self.db).read()["credential"], credential)
        self.assertEqual(len(self.api.profiles), 1)

    def test_parallel_registration_is_race_safe(self):
        barrier = threading.Barrier(4)
        results = []

        def register():
            barrier.wait()
            results.append(self.join())

        threads = [threading.Thread(target=register) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        self.assertEqual({item["status"] for item in results}, {"active"})
        self.assertEqual(len({item["id"] for item in results}), 1)
        self.assertEqual(len(self.api.profiles), 1)

    def test_pause_during_registration_is_preserved_and_resume_keeps_identity(self):
        def pausing_request(*args, **kwargs):
            set_paused(self.db, True)
            return self.api.request(*args, **kwargs)

        profile = register_profile(self.db, "Permanent", request=pausing_request)
        self.assertEqual(profile["status"], "paused")
        state = ProfileStore(self.db).read()
        resumed = set_paused(self.db, False)
        self.assertEqual(resumed["status"], "active")
        self.assertEqual(resumed["nickname"], "Permanent")
        self.assertEqual(ProfileStore(self.db).read()["credential"], state["credential"])

    def test_corrupt_identity_is_not_silently_replaced(self):
        self.join()
        path = ProfileStore(self.db).path
        with path.open("w") as handle:
            handle.write("malformed")
        self.assertEqual(profile_status(self.db)["error"], "profile_corrupt")
        self.assertEqual(self.join()["error"], "profile_corrupt")
        self.assertEqual(path.read_text(), "malformed")

    def test_aggregate_uses_join_timestamp_and_shanghai_day_excludes_simulations(self):
        self.event("before", "2026-09-07T15:59:59+00:00", 1000)
        self.event("first", "2026-09-07T16:00:00+00:00", 25)
        self.event("offset", "2026-09-08T02:00:00+09:00", 30)
        self.event("simulation:one", "2026-09-08T00:00:00+00:00", 1_000_000)
        self.event("other-synthetic", "2026-09-08T01:00:00+00:00", 2_000_000, "simulation")
        self.event("tomorrow", "2026-09-08T16:00:00+00:00", 10)
        self.event("future", "2026-09-09T16:00:00+00:00", 1000)
        # Deliberately wrong local_date proves aggregation does not reuse host-local dates.
        self.store.connection.execute("UPDATE usage_events SET local_date='1999-01-01'")
        self.store.connection.commit()
        before = self.store.totals(datetime.now().astimezone())
        days = aggregate_days(self.db, "2026-09-07T16:00:00Z",
                              now=datetime(2026, 9, 8, 17, tzinfo=timezone.utc))
        self.assertEqual(days, [{"date": "2026-09-08", "total_tokens": 55},
                                {"date": "2026-09-09", "total_tokens": 10}])
        self.assertEqual(self.store.totals(datetime.now().astimezone()), before)

    def test_aggregate_backfills_at_most_seven_days_without_fictional_zero_rows(self):
        self.event("too-old", "2026-08-31T15:59:59+00:00", 200)
        self.event("oldest", "2026-08-31T16:00:00+00:00", 300)
        self.event("today", "2026-09-07T16:00:00+00:00", 400)
        days = aggregate_days(self.db, "2026-01-01T00:00:00Z",
                              now=datetime(2026, 9, 8, 0, tzinfo=timezone.utc))
        self.assertEqual(days, [{"date": "2026-09-01", "total_tokens": 300},
                                {"date": "2026-09-08", "total_tokens": 400}])

    def test_public_board_is_sanitized_and_failure_retains_last_success(self):
        self.join()
        board = read_leaderboard(self.db, request=self.api.request)
        self.assertEqual(board["status"], "ok")
        self.assertIsNone(board["own_entry"])
        self.assertNotIn("identity", self.api.calls[-1][2])
        self.api.fail = "offline"
        failed = read_leaderboard(self.db, previous=board, request=self.api.request)
        self.assertEqual(failed["status"], "offline")
        self.assertTrue(failed["stale"])
        self.assertEqual(failed["updated_at"], board["updated_at"])

    def test_malformed_board_never_becomes_demo_or_valid_zero(self):
        for payload in [{}, {"entries": "bad"}, {"error": "offline"}]:
            board = read_leaderboard(self.db, request=lambda *a, **k: payload)
            self.assertEqual(board["status"], "offline")
            self.assertEqual(board["error"], "invalid_response")
            self.assertFalse(board["stale"])

    def test_pagination_and_own_rank(self):
        own = self.join()
        entry = {"id": str(uuid.uuid4()), "rank": 51, "nickname": "Page Two", "total_tokens": 400}
        my_entry = {"id": own["id"], "rank": 72, "nickname": own["nickname"], "total_tokens": 10}
        def response(method, path, **kwargs):
            self.assertIn("offset=50&limit=50", path)
            return {"date": "2026-09-07", "time_zone": "Asia/Shanghai", "entries": [entry],
                    "total_participants": 72, "own_entry": my_entry, "updated_at": "2026-09-08T00:00:00Z"}
        board = read_leaderboard(self.db, offset=50, request=response)
        self.assertEqual(board["entries"][0]["rank"], 51)
        self.assertEqual(board["own_entry"]["rank"], 72)

    def test_no_usage_upload_before_create_or_while_paused(self):
        for paused in [False, True]:
            if paused:
                self.api.joined = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
                self.join()
                self.event("real", datetime.now(timezone.utc).isoformat())
                set_paused(self.db, True)
            self.api.calls.clear()
            worker = LeaderboardWorker(self.db, interval=300, request=self.api.request)
            worker.start()
            self.wait_until(lambda: worker.snapshot()["leaderboard"]["status"] == "ok")
            worker.stop()
            self.assertTrue(all(call[0] == "GET" for call in self.api.calls))

    def test_worker_uploads_absolute_aggregate_after_join(self):
        now = datetime.now(timezone.utc)
        self.api.joined = (now - timedelta(minutes=10)).isoformat()
        self.join()
        self.event("actual", (now - timedelta(minutes=1)).isoformat(), 725)
        self.event("pre-join", (now - timedelta(days=1)).isoformat(), 9000)
        worker = LeaderboardWorker(self.db, interval=300, request=self.api.request)
        worker.start()
        self.wait_until(lambda: bool(self.api.days))
        worker.stop()
        self.assertEqual(list(self.api.days.values()), [725])
        self.assertNotIn("credential", json.dumps(worker.snapshot()))

    def test_repeated_sync_submits_absolute_totals_not_increments(self):
        now = datetime.now(timezone.utc)
        self.api.joined = (now - timedelta(minutes=10)).isoformat()
        self.join()
        self.event("real", (now - timedelta(minutes=1)).isoformat(), 123)
        for _ in range(2):
            worker = LeaderboardWorker(self.db, interval=300, request=self.api.request)
            previous_calls = len(self.api.calls)
            worker.start()
            self.wait_until(lambda: worker.snapshot()["leaderboard"]["status"] == "ok")
            worker.stop()
            self.assertGreater(len(self.api.calls), previous_calls)
        payloads = [call[2]["payload"]["days"] for call in self.api.calls if call[1] == "/api/v1/usage"]
        self.assertEqual(len(payloads), 2)
        self.assertEqual(payloads[0], payloads[1])
        self.assertEqual(list(self.api.days.values()), [123])

    def test_upload_failure_is_visible_even_when_public_board_is_fresh_then_clears_on_success(self):
        now = datetime.now(timezone.utc)
        self.api.joined = (now - timedelta(minutes=10)).isoformat()
        self.join()
        identity = ProfileStore(self.db).read()
        self.event("actual", (now - timedelta(minutes=1)).isoformat(), 123)
        def broken_upload(method, path, **kwargs):
            if path == "/api/v1/usage":
                raise LeaderboardError("unauthorized")
            return self.api.request(method, path, **kwargs)
        worker = LeaderboardWorker(self.db, request=broken_upload)
        worker.start()
        self.wait_until(lambda: worker.snapshot()["leaderboard"].get("error") == "sync_failed")
        worker.stop()
        failed = worker.snapshot()
        self.assertEqual(failed["profile"]["status"], "active")
        self.assertEqual(failed["profile"]["error"], "unauthorized")
        self.assertEqual(failed["leaderboard"]["status"], "ok")
        self.assertFalse(failed["leaderboard"]["stale"])
        self.assertTrue(failed["leaderboard"]["own_entry_stale"])
        self.assertEqual(profile_status(self.db)["error"], "unauthorized")
        recovered = LeaderboardWorker(self.db, request=self.api.request)
        recovered.start()
        self.wait_until(lambda: recovered.snapshot()["leaderboard"]["status"] == "ok")
        recovered.stop()
        self.assertIsNone(recovered.snapshot()["profile"]["error"])
        self.assertNotIn("error", recovered.snapshot()["leaderboard"])
        self.assertFalse(recovered.snapshot()["leaderboard"]["own_entry_stale"])
        self.assertEqual(ProfileStore(self.db).read()["credential"], identity["credential"])
        self.assertEqual(profile_status(self.db)["nickname"], identity["nickname"])

    def test_upload_error_is_sanitized_and_pause_does_not_claim_fresh_own_row(self):
        now = datetime.now(timezone.utc)
        self.api.joined = (now - timedelta(minutes=10)).isoformat()
        self.join()
        self.event("actual", (now - timedelta(minutes=1)).isoformat())
        def broken_upload(method, path, **kwargs):
            if path == "/api/v1/usage":
                raise LeaderboardError("Bearer secret-never-emit")
            return self.api.request(method, path, **kwargs)
        worker = LeaderboardWorker(self.db, request=broken_upload)
        worker.start()
        self.wait_until(lambda: worker.snapshot()["leaderboard"].get("error") == "sync_failed")
        worker.stop()
        self.assertEqual(worker.snapshot()["profile"]["error"], "usage_unavailable")
        self.assertNotIn("secret-never-emit", json.dumps(worker.snapshot()))
        set_paused(self.db, True)
        paused = LeaderboardWorker(self.db, request=broken_upload)
        paused.start()
        self.wait_until(lambda: paused.snapshot()["leaderboard"]["status"] == "ok")
        paused.stop()
        self.assertEqual(paused.snapshot()["profile"]["status"], "paused")
        self.assertTrue(paused.snapshot()["leaderboard"]["own_entry_stale"])
        self.assertEqual(self.api.days, {})

    def test_service_url_requires_https_except_loopback(self):
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com?q=secret", "file:///tmp/data"]:
            with patch.dict(os.environ, {URL_OVERRIDE: url}), self.assertRaises(LeaderboardError):
                service_url()
        for url in ["https://example.com", "http://127.0.0.1:1234", "http://[::1]:1234", "http://localhost:1234"]:
            with patch.dict(os.environ, {URL_OVERRIDE: url}):
                self.assertEqual(service_url(), url)
        with patch.dict(os.environ, {URL_OVERRIDE: ""}):
            self.assertEqual(read_leaderboard(self.db)["status"], "not_configured")

    def test_http_redirect_does_not_forward_bearer(self):
        received = []
        def handler(request):
            received.append((request.path, request.headers.get("Authorization")))
            request.send_response(302)
            request.send_header("Location", "/stolen")
            request.end_headers()
        with http_service(handler) as url, patch.dict(os.environ, {URL_OVERRIDE: url}):
            with self.assertRaises(LeaderboardError) as caught:
                request_json("POST", "/api/v1/installations", identity={"id": str(uuid.uuid4()), "credential": "synthetic"}, payload={})
        self.assertEqual(caught.exception.code, "redirect_blocked")
        self.assertEqual(received, [("/api/v1/installations", "Bearer synthetic")])

    def test_real_http_malformed_error_is_sanitized(self):
        def handler(request):
            body = json.dumps({"error": {"secret": "never-emit"}}).encode()
            request.send_response(500)
            request.send_header("Content-Length", str(len(body)))
            request.end_headers()
            request.wfile.write(body)
        with http_service(handler) as url, patch.dict(os.environ, {URL_OVERRIDE: url}):
            result = register_profile(self.db, "Offline")
        self.assertEqual(result["error"], "service_error")
        self.assertEqual(result["status"], "pending")
        self.assertNotIn("never-emit", json.dumps(result))

    def test_cli_status_does_not_scan_or_disclose_credential(self):
        self.join()
        state = ProfileStore(self.db).read()
        env = dict(os.environ)
        env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1] / "src")
        result = subprocess.run([sys.executable, "-m", "codex_token_counter.cli", "--db", str(self.db),
                                 "profile-status"], capture_output=True, text=True, env=env, timeout=3)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["profile"]["status"], "active")
        self.assertNotIn(state["credential"], result.stdout + result.stderr)
        self.assertIsNone(self.store.get_metadata("installed_at"))

    def test_stream_counter_emits_without_waiting_for_network(self):
        blocked = threading.Event()
        release = threading.Event()
        def handler(request):
            blocked.set()
            release.wait(5)
            try:
                payload = json.dumps(self.api.request("GET", request.path)).encode()
                request.send_response(200)
                request.send_header("Content-Length", str(len(payload)))
                request.end_headers()
                request.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass
        with http_service(handler) as url:
            env = dict(os.environ, **{URL_OVERRIDE: url})
            env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1] / "src")
            started = time.monotonic()
            process = subprocess.Popen([sys.executable, "-m", "codex_token_counter.cli", "--db", str(self.db),
                                        "--sessions", str(self.db.parent / "no-sessions"), "stream", "--interval", "300", "--leaderboard"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            received = queue.Queue()
            reader = threading.Thread(target=lambda: received.put(process.stdout.readline()), daemon=True)
            reader.start()
            try:
                output = received.get(timeout=2)
                snapshot = json.loads(output)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(snapshot["today"], 0)
                self.assertEqual(snapshot["profile"]["status"], "needs_name")
                self.assertEqual(snapshot["leaderboard"]["status"], "loading")
                self.assertNotIn("credential", output)
            finally:
                release.set()
                process.terminate()
                process.wait(timeout=3)
                process.stdout.close()
                process.stderr.close()
                reader.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
