import Foundation

/// The visual style is independent of counting, window visibility, and other preferences.
enum ObserverAppearance: String, CaseIterable, Identifiable, Sendable {
    case mist
    case classic

    static let preferenceKey = "observerAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mist: "Mist"
        case .classic: "Classic"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let appearance = Self(rawValue: rawValue) else {
            return .mist
        }
        return appearance
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
