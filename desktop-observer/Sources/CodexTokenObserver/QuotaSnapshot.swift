import Foundation

/// Current account allowance, independent of historical token activity and reset carry.
struct QuotaSnapshot: Decodable {
    let available: Bool
    let currentPercent: Double?
    let cumulativePercent: Double?
    let resetsAt: Double?
    let observedAt: String?
    let resetCount: Int?
    let stale: Bool
    let estimated: Bool

    enum CodingKeys: String, CodingKey {
        case available, stale, estimated
        case currentPercent = "current_percent", cumulativePercent = "cumulative_percent"
        case resetsAt = "resets_at", observedAt = "observed_at", resetCount = "reset_count"
    }

    var usedPercent: Double? {
        guard available || stale,
              let currentPercent, currentPercent.isFinite, currentPercent >= 0 else { return nil }
        return min(100, currentPercent)
    }

    var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
    var isExhausted: Bool { (usedPercent ?? 0) >= 100 }

    var detail: String {
        guard let usedPercent, let remainingPercent else {
            return "Waiting for weekly quota. Sign in to Codex to view your account allowance."
        }
        var detail = "Main Codex account weekly quota. Remaining: \(String(format: "%.0f", remainingPercent))%. Used: \(String(format: "%.0f", usedPercent))%."
        detail += " Follows account quota resets; no pre-reset usage is added."
        detail += " This is an account allowance, not a fixed token count."
        if let resetsAt, resetsAt.isFinite {
            let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US"))
            detail += " Window ends: \(Date(timeIntervalSince1970: resetsAt).formatted(dateStyle))."
        }
        if stale { detail += " Showing the last available reading while waiting for an update." }
        return detail
    }
}
