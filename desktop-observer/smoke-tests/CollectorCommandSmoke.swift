import Foundation

/// Run with the repository root argument. Uses a fresh temporary data directory,
/// an explicitly disabled network URL, and read-only CLI commands only.
@main
struct CollectorCommandSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the repository root") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("zuno-native-command-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let command = CollectorCommand(resources: root,
                                       database: temporary.appendingPathComponent("fixture.sqlite3"),
                                       environment: ["PYTHONPATH": root.appendingPathComponent("src").path,
                                                     "PYTHONUNBUFFERED": "1", "ZUNO_LEADERBOARD_URL": ""])
        let built = command.makeProcess(arguments: ["profile-status"])
        precondition(built.arguments == ["-m", "codex_token_counter.cli", "--db", command.database.path, "profile-status"])
        precondition(built.currentDirectoryURL == root)
        struct Reply: Decodable { let profile: ZunoProfile }
        guard let status = await command.run(arguments: ["profile-status"]) else { fatalError("Missing CLI profile response") }
        let profile = try JSONDecoder().decode(Reply.self, from: status).profile
        precondition(profile.status == "needs_name" && profile.id == nil && profile.nickname == nil)
        precondition(!String(decoding: status, as: UTF8.self).contains("credential"))
        guard let data = await command.run(arguments: ["leaderboard-read", "--offset", "50", "--limit", "50"]) else {
            fatalError("Error exits must still return sanitized JSON")
        }
        let board = try JSONDecoder().decode(LeaderboardSnapshot.self, from: data)
        precondition(board.status == "not_configured" && board.entries.isEmpty && !board.isSample)
        let files = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        precondition(!files.contains(where: { $0.hasSuffix(".json") || $0.hasSuffix(".sqlite3") }),
                     "Read-only profile and leaderboard views must not create an identity or ledger")
        print("Native collector-command smoke passed: isolated db/env, real Python profile JSON, error-exit board JSON, no credential in response, no account/ledger/identity creation and no network configured.")
    }
}
