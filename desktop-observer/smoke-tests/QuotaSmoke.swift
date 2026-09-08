import Foundation

/// Compile with QuotaSnapshot.swift only. No account, app process, preferences, or ledger is opened.
@main
struct QuotaSmoke {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func quota(current: Double?, cumulative: Double? = 190, available: Bool = true,
                   stale: Bool = false, estimated: Bool = false, resetsAt: Double? = nil) -> QuotaSnapshot {
            QuotaSnapshot(available: available, currentPercent: current, cumulativePercent: cumulative,
                          resetsAt: resetsAt, observedAt: "2026-09-08T12:00:00Z", resetCount: 2,
                          stale: stale, estimated: estimated)
        }

        let live = quota(current: 7, cumulative: 97, estimated: true)
        check(live.usedPercent == 7, "Current usage must not include pre-reset carry")
        check(live.remainingPercent == 93, "Show the complement of current usage")
        check(!live.isExhausted, "Carry must not trigger exhausted styling")
        check(live.detail.contains("Remaining: 93%. Used: 7%."), "Help must clearly separate remaining and used percentages")
        check(live.detail.contains("Follows account quota resets; no pre-reset usage is added."), "Explain reset behavior")
        check(live.detail.contains("not a fixed token count"), "Do not imply a fixed number of remaining tokens")
        check(!live.detail.contains("≈") && !live.detail.lowercased().contains("cumulative"), "Do not label current allowance as estimated cumulative usage")
        check(!live.detail.lowercased().contains("estimated"), "Historical carry estimates must not mark current usage as estimated")

        for carry in [0.0, 90, 190, 900, Double.nan, Double.infinity] {
            let reset = quota(current: 0, cumulative: carry)
            check(reset.usedPercent == 0 && reset.remainingPercent == 100, "An observed account reset must restore 100% regardless of historical carry")
            check(!reset.isExhausted, "A reset cannot be exhausted")
        }
        for used in [100.0, 101, 500] {
            let exhausted = quota(current: used)
            check(exhausted.usedPercent == 100 && exhausted.remainingPercent == 0, "Over-limit readings must clamp to the allowance range")
            check(exhausted.isExhausted, "100% used must be exhausted")
        }
        let fractional = quota(current: 99.75)
        check(fractional.usedPercent == 99.75 && fractional.remainingPercent == 0.25, "Keep precision in the model, rounding only in presentation")
        check(!fractional.isExhausted, "Rounding must not falsely mark a nonempty allowance as exhausted")

        let stale = quota(current: 12, available: false, stale: true)
        check(stale.remainingPercent == 88, "A stale reading can show the last known current allowance")
        check(stale.detail.contains("Showing the last available reading"), "Stale values must be explicitly qualified")
        check(!live.detail.contains("Showing the last available reading"), "Fresh readings must not be labeled stale")
        let unavailable = quota(current: 12, available: false)
        check(unavailable.usedPercent == nil && unavailable.remainingPercent == nil, "An unavailable reading without a stale flag must remain unknown")
        check(!unavailable.isExhausted, "Unknown is not exhausted")

        for invalid: Double? in [nil, .nan, .infinity, -.infinity, -1] {
            let unknown = quota(current: invalid, cumulative: 50, stale: true)
            check(unknown.usedPercent == nil && unknown.remainingPercent == nil, "Invalid current usage must not fall back to cumulative usage")
            check(unknown.detail.hasPrefix("Waiting for weekly quota."), "Unknown usage must not fabricate a remaining percentage")
            check(!unknown.isExhausted, "Invalid usage must not appear exhausted")
        }
        check(quota(current: 0, resetsAt: 1_789_240_231).detail.contains("Window ends:"), "Preserve the account window deadline")
        check(!quota(current: 0, resetsAt: .nan).detail.contains("Window ends:"), "Invalid deadlines must not be formatted")

        let data = Data(#"{"available":true,"current_percent":6,"cumulative_percent":196,"resets_at":1789240231,"observed_at":"2026-09-08T12:00:00Z","reset_count":2,"stale":false,"estimated":true}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        check(decoded.remainingPercent == 94, "Decode the existing collector protocol")
        check(decoded.cumulativePercent == 196 && decoded.resetCount == 2 && decoded.estimated, "Keep legacy metadata for protocol compatibility without displaying it")
        check(decoded.observedAt == "2026-09-08T12:00:00Z" && decoded.resetsAt == 1_789_240_231, "Preserve freshness and reset metadata")
        let missing = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"available":true,"stale":false,"estimated":false,"cumulative_percent":20}"#.utf8))
        check(missing.remainingPercent == nil, "Missing optional current usage remains unknown even with cumulative usage")
        check(missing.detail.allSatisfy(\.isASCII), "Waiting help remains English-only")
        check(live.detail.allSatisfy(\.isASCII), "Live quota help remains English-only")

        print("Quota smoke passed: \(checks) checks; current-only remaining allowance, resets, clamping, stale/unknown handling, English help, and collector compatibility.")
    }
}
