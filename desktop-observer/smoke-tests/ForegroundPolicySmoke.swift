import AppKit

/// Compile with ForegroundPolicy.swift as a standalone executable. No app launch,
/// window ordering, user preference changes, or persistent writes are performed.
@main
struct ForegroundPolicySmoke {
    @MainActor
    static func main() {
        let accepted = ["com.openai.codex", "com.openai.chat"]
        for identifier in accepted {
            precondition(ForegroundPolicy.shouldFloat(bundleIdentifier: identifier), identifier)
        }

        let rejected: [String?] = [
            nil, "", "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.openai.chatgpt", "com.openai.nativeCodex", "com.openai.codex.helper",
            "com.example.codex", "COM.OPENAI.CODEX"
        ]
        for identifier in rejected {
            precondition(!ForegroundPolicy.shouldFloat(bundleIdentifier: identifier), "Unexpected allow: \(identifier ?? "nil")")
        }

        let observerID = "test.token.observer"
        func state(_ activated: String?, previous: Bool?) -> Bool {
            ForegroundPolicy.resolvedState(
                bundleIdentifier: activated,
                ownBundleIdentifier: observerID,
                previousState: previous
            )
        }

        // Opening the widget's own menu preserves the previous external app state.
        precondition(state(observerID, previous: true))
        precondition(!state(observerID, previous: false))
        precondition(!state(observerID, previous: nil))
        precondition(state("com.openai.codex", previous: false))
        precondition(state("com.openai.chat", previous: false))
        precondition(!state("com.apple.Safari", previous: true))
        precondition(!state(nil, previous: true))

        // Check subscription lifecycle against the current workspace, read-only.
        var reports: [Bool] = []
        let policy = ForegroundPolicy { reports.append($0) }
        policy.start()
        precondition(reports.count == 1, "Start must report an initial state")
        policy.start()
        precondition(reports.count == 1, "Repeated start must not double-subscribe")
        policy.stop()
        precondition(reports.count == 1, "Stop must not change window state")
        policy.start()
        precondition(reports.count == 2, "Restart must report the current state")
        policy.stop()

        print("ForegroundPolicy smoke passed: exact native allowlist, browser rejection, own-app state preservation, and subscription lifecycle.")
    }
}
