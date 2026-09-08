import Foundation

struct LeaderboardEntry: Identifiable, Equatable, Decodable, Sendable {
    let id: String
    let rank: Int
    let nickname: String
    let totalTokens: Int64
    enum CodingKeys: String, CodingKey {
        case id, rank, nickname
        case totalTokens = "total_tokens"
    }
}

/// Public, sanitized state from the shared collector. No credentials enter the UI.
struct ZunoProfile: Equatable, Decodable, Sendable {
    let status: String
    let id: String?
    let nickname: String?
    let error: String?
    var hasIdentity: Bool { id != nil && nickname != nil && status != "needs_name" }
    var isRegistered: Bool { status == "active" || status == "paused" }
    var isPaused: Bool { status == "paused" }
    var errorMessage: String? { ZunoProfile.message(for: error) }

    static func message(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        switch code {
        case "nickname_taken": return "That name is already taken. Please choose another."
        case "invalid_nickname": return "Use 2–24 letters, numbers, spaces, _ or -."
        case "identity_conflict": return "This installation could not be verified. Your local counts are safe."
        case "registration_pending": return "Your first name is already being registered. Retry with that name."
        case "immutable_nickname": return "This installation already has a permanent nickname. It cannot be changed."
        case "sync_failed": return "Your usage has not synced yet. Zuno will retry automatically. The public ranking may still refresh."
        case "rate_limited": return "Too many requests. Please wait a little and try again."
        case "not_configured": return "The leaderboard service is not configured yet. Local counting continues."
        default: return "Could not reach the leaderboard. Your local counts are safe. Please retry."
        }
    }

    /// Same NFKC and code-point policy as the service; the server remains authoritative.
    static func normalizedNickname(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(normalized.unicodeScalars.count) else { return nil }
        let valid = normalized.unicodeScalars.allSatisfy { scalar in
            if scalar == " " || scalar == "_" || scalar == "-" { return true }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
        return valid ? normalized : nil
    }
}

struct LeaderboardSnapshot: Equatable, Decodable, Sendable {
    let status: String
    let date: String
    let timeZone: String
    let entries: [LeaderboardEntry]
    let totalParticipants: Int
    let ownEntry: LeaderboardEntry?
    let updatedAt: String?
    let stale: Bool
    let error: String?
    let ownEntryStale: Bool
    let isSample: Bool

    enum CodingKeys: String, CodingKey {
        case status, date, entries, stale, error
        case timeZone = "time_zone", totalParticipants = "total_participants"
        case ownEntry = "own_entry", updatedAt = "updated_at"
        case ownEntryStale = "own_entry_stale"
    }
    var dateLabel: String { date }
    var timeZoneLabel: String { timeZone }
    var ownEntryOutsidePage: LeaderboardEntry? {
        guard let ownEntry, !entries.contains(where: { $0.id == ownEntry.id }) else { return nil }
        return ownEntry
    }

    init(status: String = "loading", date: String = Self.yesterday(), timeZone: String = "Asia/Shanghai",
         entries: [LeaderboardEntry] = [], totalParticipants: Int = 0,
         ownEntry: LeaderboardEntry? = nil, updatedAt: String? = nil,
         stale: Bool = false, error: String? = nil, ownEntryStale: Bool = false, isSample: Bool = false) {
        self.status = status; self.date = date; self.timeZone = timeZone
        self.entries = entries; self.totalParticipants = totalParticipants
        self.ownEntry = ownEntry; self.updatedAt = updatedAt
        self.stale = stale; self.isSample = isSample
        self.error = error; self.ownEntryStale = ownEntryStale
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        date = try values.decode(String.self, forKey: .date)
        timeZone = try values.decode(String.self, forKey: .timeZone)
        entries = try values.decode([LeaderboardEntry].self, forKey: .entries)
        totalParticipants = try values.decode(Int.self, forKey: .totalParticipants)
        ownEntry = try values.decodeIfPresent(LeaderboardEntry.self, forKey: .ownEntry)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        stale = try values.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        error = try values.decodeIfPresent(String.self, forKey: .error)
        ownEntryStale = try values.decodeIfPresent(Bool.self, forKey: .ownEntryStale) ?? false
        isSample = false
    }

    static func yesterday(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let previous = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: previous)
    }

    func asOffline() -> Self {
        Self(status: "offline", date: date, timeZone: timeZone, entries: entries,
             totalParticipants: totalParticipants, ownEntry: ownEntry,
             updatedAt: updatedAt, stale: !entries.isEmpty || updatedAt != nil,
             error: error, ownEntryStale: true)
    }

    #if DEBUG
    /// Debug fixtures never enter runtime state or act as a network fallback.
    static func sample(now: Date = Date()) -> Self {
        let participants: [(String, String, Int64)] = [
            ("demo-mochi", "Mochi", 28_604_712), ("demo-orbit", "Orbit", 24_391_805),
            ("demo-pixel", "Pixel", 19_780_246), ("demo-willow", "Willow", 16_420_093),
            ("demo-nova", "Nova", 13_708_561), ("demo-clover", "Clover", 11_294_807),
            ("demo-echo", "Echo", 8_906_324), ("demo-miso", "Miso", 6_310_482),
            ("demo-juniper", "Juniper", 3_805_176), ("demo-pebble", "Pebble", 1_927_640)
        ]
        let entries = participants.enumerated().map {
            LeaderboardEntry(id: $0.element.0, rank: $0.offset + 1,
                             nickname: $0.element.1, totalTokens: $0.element.2)
        }
        return Self(status: "ok", date: yesterday(now: now), entries: entries,
                    totalParticipants: 126,
                    ownEntry: LeaderboardEntry(id: "demo-you", rank: 86, nickname: "小庄", totalTokens: 86_204),
                    isSample: true)
    }
    #endif
}
