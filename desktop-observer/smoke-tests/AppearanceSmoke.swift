import Foundation

/// Compile with ObserverAppearance.swift as a standalone executable.
/// All writes use a unique test suite; the app's preferences and ledger are untouched.
@main
struct AppearanceSmoke {
    static func main() {
        let suiteName = "test.codex-token-observer.appearance.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        precondition(ObserverAppearance.allCases == [.mist, .classic])
        precondition(ObserverAppearance.mist.id == "mist")
        precondition(ObserverAppearance.classic.id == "classic")
        precondition(ObserverAppearance.mist.title == "Mist")
        precondition(ObserverAppearance.classic.title == "Classic")
        precondition(ObserverAppearance.load(from: defaults) == .mist, "New installs use Mist")
        precondition(defaults.persistentDomain(forName: suiteName) == nil, "Loading must not write preferences")

        let untouched: [String: Any] = [
            "showPanelBackground": false,
            "followsTargetApps": true,
            "demoTotalEnabled": true,
            "panelCorner": "left",
            "unrelatedPreference": "preserve me"
        ]
        for (key, value) in untouched { defaults.set(value, forKey: key) }

        func verifyUnrelatedPreferences() {
            let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
            for (key, value) in untouched {
                precondition(
                    NSDictionary(dictionary: [key: domain[key] as Any]).isEqual(to: [key: value]),
                    "Appearance changed unrelated preference: \(key)"
                )
            }
            precondition(
                Set(domain.keys).isSubset(of: Set(untouched.keys).union([ObserverAppearance.preferenceKey])),
                "Appearance wrote an unexpected preference"
            )
        }

        for appearance in ObserverAppearance.allCases {
            appearance.save(to: defaults)
            precondition(defaults.string(forKey: ObserverAppearance.preferenceKey) == appearance.rawValue)
            guard let reloaded = UserDefaults(suiteName: suiteName) else {
                fatalError("Could not reopen isolated preferences")
            }
            precondition(ObserverAppearance.load(from: reloaded) == appearance, "Selection did not survive reload")
            verifyUnrelatedPreferences()
        }

        for invalid in ["", "unknown-style", "Mist", "CLASSIC"] {
            defaults.set(invalid, forKey: ObserverAppearance.preferenceKey)
            precondition(ObserverAppearance.load(from: defaults) == .mist)
            precondition(defaults.string(forKey: ObserverAppearance.preferenceKey) == invalid, "Loading must be read-only")
            verifyUnrelatedPreferences()
        }
        defaults.set(42, forKey: ObserverAppearance.preferenceKey)
        precondition(ObserverAppearance.load(from: defaults) == .mist, "Invalid preference types fall back to Mist")
        verifyUnrelatedPreferences()

        defaults.removeObject(forKey: ObserverAppearance.preferenceKey)
        precondition(ObserverAppearance.load(from: defaults) == .mist)
        verifyUnrelatedPreferences()

        print("Appearance smoke passed: Mist default, both style round-trips, invalid-value fallback, read-only loading, and unrelated preference preservation.")
    }
}
