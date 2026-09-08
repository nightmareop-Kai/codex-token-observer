import Foundation

/// Compile with LeaderboardSnapshot.swift; no app, preferences, ledger, or network is opened.
@main
struct LeaderboardSmoke {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        let empty = LeaderboardSnapshot()
        check(empty.status == "loading" && empty.entries.isEmpty && !empty.isSample, "Runtime never defaults to sample participants")
        let decoder = JSONDecoder()
        let payload = """
        {"status":"ok","date":"2026-09-07","time_zone":"Asia/Shanghai", "entries":[
          {"id":"synthetic-a","rank":51,"nickname":"Alpha","total_tokens":9007199254740991}],
          "total_participants":123,"own_entry":{"id":"synthetic-me","rank":99,"nickname":"小庄","total_tokens":42},
          "updated_at":"2026-09-08T00:01:00+08:00","stale":false,"isSample":true}
        """
        let board = try decoder.decode(LeaderboardSnapshot.self, from: Data(payload.utf8))
        check(board.entries.count == 1 && board.entries[0].rank == 51, "Keep server ranks when paginating, never rerank a page")
        check(board.entries[0].totalTokens == 9_007_199_254_740_991, "Keep exact safe integer totals")
        check(board.totalParticipants == 123, "Keep global participant count")
        check(board.ownEntryOutsidePage?.rank == 99, "Display own rank outside current page")
        check(!board.isSample, "Network input cannot mark itself as a fixture")
        check(board.timeZoneLabel == "Asia/Shanghai" && board.dateLabel == "2026-09-07", "Show server date, not local calendar")
        let offline = board.asOffline()
        check(offline.stale && offline.status == "offline", "Failed refresh marks prior data stale")
        check(offline.entries == board.entries && offline.updatedAt == board.updatedAt, "Failed refresh retains exact prior snapshot")
        check(offline.ownEntry == board.ownEntry, "Offline cache retains own rank")
        check(!board.ownEntryStale && board.error == nil, "Older optional-field schema remains compatible")
        let syncFailureData = payload.replacingOccurrences(of: "\"stale\":false", with: "\"stale\":false,\"own_entry_stale\":true,\"error\":\"sync_failed\"")
        let syncFailure = try decoder.decode(LeaderboardSnapshot.self, from: Data(syncFailureData.utf8))
        check(syncFailure.status == "ok" && !syncFailure.stale && syncFailure.ownEntryStale && syncFailure.error == "sync_failed",
              "Fresh global ranking and failed personal upload are separate states")
        check(syncFailure.asOffline().ownEntryStale, "Personal pending state survives offline fallback")
        check(!empty.asOffline().stale, "No previous data does not pretend to be cached")
        let ownVisible = LeaderboardSnapshot(status: "ok", entries: board.entries, ownEntry: board.entries.first)
        check(ownVisible.ownEntryOutsidePage == nil, "Never duplicate the own row already visible")
        let iso = ISO8601DateFormatter()
        check(LeaderboardSnapshot.yesterday(now: iso.date(from: "2025-12-31T16:01:00Z")!) == "2025-12-31", "Beijing midnight crosses year regardless of machine zone")
        check(LeaderboardSnapshot.yesterday(now: iso.date(from: "2024-02-29T16:01:00Z")!) == "2024-02-29", "Beijing yesterday handles leap day")
        check(LeaderboardSnapshot.yesterday(now: iso.date(from: "2026-09-07T15:59:00Z")!) == "2026-09-06", "Before Beijing midnight")
        check(LeaderboardSnapshot.yesterday(now: iso.date(from: "2026-09-07T16:00:00Z")!) == "2026-09-07", "At Beijing midnight")

        let profiles: [(String, Bool, Bool)] = [("needs_name", false, false), ("pending", false, false),
                                               ("active", true, false), ("paused", true, true), ("error", false, false)]
        for (status, registered, paused) in profiles {
            let profile = try decoder.decode(ZunoProfile.self, from: Data("{\"status\":\"\(status)\",\"id\":null,\"nickname\":null,\"error\":null}".utf8))
            check(profile.isRegistered == registered && profile.isPaused == paused, "Profile status \(status) is correctly interpreted")
        }
        for valid in ["小庄", "Mochi", "Zuno-86", "my_name", "A B", "12", String(repeating: "庄", count: 24)] {
            check(ZunoProfile.normalizedNickname(valid) == valid, "Accept allowed nickname \(valid)")
        }
        check(ZunoProfile.normalizedNickname("  Ｚｕｎｏ  ") == "Zuno", "Normalize NFKC and trim before submission")
        for invalid in ["", "A", String(repeating: "庄", count: 25), "<script>", "hello\nworld", "A\u{202e}B", "🐱🐱", "@Kai", "A\u{200d}B"] {
            check(ZunoProfile.normalizedNickname(invalid) == nil, "Reject invalid/control/markup nickname")
        }
        check(ZunoProfile.message(for: "nickname_taken")?.contains("taken") == true, "Uniqueness error is actionable")
        check(ZunoProfile.message(for: "<secret-server-text>")?.contains("secret") == false, "Unknown server error text is never echoed")
        #if DEBUG
        check(LeaderboardSnapshot.sample().isSample && LeaderboardSnapshot.sample().entries.count == 10, "Only explicit debug factory supplies fictional entries")
        #endif
        print("Leaderboard/profile smoke passed: \(checks) checks; real decoding, integer totals, pagination own-rank, stale retention, UTC+08 rollover, permanent-profile states, nickname validation and sanitized errors.")
    }
}
