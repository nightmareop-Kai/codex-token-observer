import SwiftUI

struct LeaderboardPalette {
    let appearance: ObserverAppearance
    let dark: Bool

    var ink: Color {
        if appearance == .classic { return ObserverStyle.silver }
        return dark ? Color(red: 0.94, green: 0.95, blue: 0.97) : Color(red: 0.12, green: 0.15, blue: 0.18)
    }
    var secondary: Color {
        if appearance == .classic { return ObserverStyle.secondary }
        return dark ? Color(red: 0.68, green: 0.72, blue: 0.78) : Color(red: 0.38, green: 0.41, blue: 0.46)
    }
    var accent: Color {
        if appearance == .classic { return ObserverStyle.accent }
        return dark ? Color(red: 0.43, green: 0.70, blue: 1) : Color(red: 0, green: 0.37, blue: 0.79)
    }
    var surface: Color {
        if appearance == .classic { return Color(red: 0.025, green: 0.045, blue: 0.065) }
        return dark ? Color(red: 0.15, green: 0.18, blue: 0.22) : Color(red: 0.96, green: 0.97, blue: 0.98)
    }
    var rule: Color { ink.opacity(dark ? 0.13 : 0.10) }
}

/// Shares the counter's footprint; the list receives any remaining vertical space.
struct LeaderboardContent: View {
    let snapshot: LeaderboardSnapshot
    let appearance: ObserverAppearance
    let showPanelBackground: Bool
    let onBack: () -> Void
    let onSelectAppearance: (ObserverAppearance) -> Void
    var profile: ZunoProfile?
    var offset = 0
    var pageSize = 50
    var loading = false
    var onRefresh: () -> Void = {}
    var onPage: (Int) -> Void = { _ in }
    var onProfile: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var backHovered = false

    private var isMist: Bool { appearance == .mist }
    private var palette: LeaderboardPalette {
        LeaderboardPalette(appearance: appearance, dark: !isMist || colorScheme == .dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigation.padding(.bottom, isMist ? 8 : 6)
            heading.padding(.bottom, isMist ? 11 : 8)
            if !snapshot.entries.isEmpty { columnLabels.padding(.bottom, 6) }
            Rectangle().fill(palette.rule).frame(height: 0.5)

            if snapshot.entries.isEmpty {
                emptyState.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.entries) { entry in
                            participantRow(entry)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
                .frame(minHeight: 0, maxHeight: .infinity)
                .background(PageInteractionExclusion())
                .accessibilityLabel("Yesterday's leaderboard")
            }

            Rectangle().fill(palette.rule).frame(height: 0.5)
            footer.padding(.top, 6)
        }
        .padding(isMist ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { panelBackground }
        .padding(ObserverStyle.outerPadding)
        .environment(\.colorScheme, isMist ? colorScheme : .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Back to Counter")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(backHovered ? palette.accent : palette.secondary)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PageInteractionExclusion())
            .onHover { backHovered = $0 }
            .help("Return to your local token counter")
            .accessibilityLabel("Back to Counter")
            Spacer(minLength: 4)
            Button(action: onProfile) {
                Image(systemName: "person.crop.circle").font(.system(size: 12))
                    .foregroundStyle(palette.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).help("Your Zuno profile")
            .accessibilityLabel("Your Zuno profile")
            .background(PageInteractionExclusion())
            AppearanceMenu(appearance: appearance, tint: palette.secondary, onSelect: onSelectAppearance)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 7) {
                Text(snapshot.stale && snapshot.date != LeaderboardSnapshot.yesterday() ? "Last available" : "Yesterday")
                    .font(isMist ? .system(size: 18, weight: .semibold)
                          : .custom("Avenir Next Condensed", size: 19).weight(.semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                Text(snapshot.isSample ? "Preview" : snapshot.stale ? "Stale" : snapshot.status == "ok" ? "Daily"
                     : snapshot.status == "loading" ? "Loading" : "Offline")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(palette.accent.opacity(0.10), in: Capsule())
            }
            Text("\(snapshot.dateLabel) · Beijing time")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
            Text(snapshot.status == "ok" ? "\(snapshot.totalParticipants) participants · Client-reported" : "Local counting continues")
                .font(.system(size: 8))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Daily ranking uses Asia/Shanghai (UTC+08), not your computer's time zone. Totals are client-reported, not verified by OpenAI.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var columnLabels: some View {
        HStack(spacing: 6) {
            Text("#").frame(width: 15, alignment: .leading)
            Text("Nickname").frame(maxWidth: .infinity, alignment: .leading)
            Text("Tokens")
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(palette.secondary)
        .accessibilityHidden(true)
    }

    private func participantRow(_ entry: LeaderboardEntry) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", entry.rank))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(entry.rank == 1 ? palette.accent : palette.secondary)
                .frame(minWidth: 15, alignment: .leading)
            Text(entry.nickname)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(entry.nickname)\nZuno ID: \(entry.id)")
            Text(entry.totalTokens.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))
                .font(.system(size: 10, weight: entry.rank == 1 ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(entry.rank == 1 ? palette.accent : palette.ink)
                .fixedSize()
        }
        .frame(height: isMist ? 27 : 25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.nickname), \(entry.totalTokens) tokens\(entry.id == profile?.id ? ", you" : "")")
        .background(entry.id == profile?.id ? palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var emptyTitle: String {
        if loading || snapshot.status == "loading" { return "Loading yesterday…" }
        if snapshot.status == "not_configured" { return "Leaderboard not available yet" }
        if snapshot.status == "offline" { return "Can't reach the leaderboard" }
        if snapshot.totalParticipants > 0 && offset > 0 { return "This page has changed" }
        return "A fresh start"
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: loading || snapshot.status == "loading" ? "clock" : snapshot.status == "ok" ? "sparkles" : "wifi.slash")
                .font(.system(size: 20, weight: .light)).foregroundStyle(palette.accent)
            Text(emptyTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.ink)
            Text(loading || snapshot.status == "loading" ? "Fetching public daily totals…"
                 : snapshot.status == "ok" && snapshot.totalParticipants > 0 && offset > 0
                 ? "No entries remain on this page.\nUse the previous-page arrow to go back."
                 : snapshot.status == "ok" ? "No activity was reported for yesterday.\nToday's activity appears tomorrow."
                 : "Your local counter keeps working.\nTry again when the service is reachable.")
                .font(.system(size: 9)).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let own = snapshot.ownEntryOutsidePage {
                HStack(spacing: 4) {
                    Text("You · #\(own.rank)").foregroundStyle(palette.accent)
                    Spacer(minLength: 2)
                    Text(own.totalTokens.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))))
                        .monospacedDigit().foregroundStyle(palette.ink)
                }.font(.system(size: 9, weight: .medium))
            } else if profile?.isRegistered == true && snapshot.ownEntry == nil && snapshot.status == "ok" {
                Text("You · No reported activity yesterday").font(.system(size: 8)).foregroundStyle(palette.secondary)
            }
            if let ownStatus {
                Text(ownStatus).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(profile?.isPaused == true ? palette.secondary : .orange)
                    .help("The public ranking can refresh even when your own usage has not been uploaded. Your local counts are unchanged.")
            }
            HStack(spacing: 7) {
                if snapshot.totalParticipants > pageSize || offset > 0 {
                    Button { onPage(max(0, offset - pageSize)) } label: {
                        Image(systemName: "chevron.left").frame(width: 18, height: 18)
                    }.disabled(offset == 0 || loading).help("Previous page").accessibilityLabel("Previous page")
                    Text("Page \(offset / pageSize + 1)")
                        .monospacedDigit().font(.system(size: 8))
                    Button { onPage(offset + pageSize) } label: {
                        Image(systemName: "chevron.right").frame(width: 18, height: 18)
                    }.disabled(offset + pageSize >= snapshot.totalParticipants || loading)
                        .help("Next page").accessibilityLabel("Next page")
                } else {
                    Text(snapshot.isSample ? "Preview · Nothing uploaded" : "Updates daily · UTC+08")
                        .font(.system(size: 8))
                }
                Spacer(minLength: 1)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10)).frame(width: 22, height: 18)
                }.disabled(loading).help("Refresh leaderboard").accessibilityLabel("Refresh leaderboard")
            }
            .buttonStyle(.plain).foregroundStyle(palette.secondary)
            .background(PageInteractionExclusion())
        }
        .help(snapshot.updatedAt.map { "Last received: \($0)" } ?? "No successful update yet")
    }

    private var ownStatus: String? {
        guard profile?.isRegistered == true else { return nil }
        if profile?.isPaused == true { return "Your usage · Sharing paused" }
        if snapshot.ownEntryStale || snapshot.error == "sync_failed" || profile?.error != nil {
            return "Your usage · Upload pending"
        }
        return nil
    }

    @ViewBuilder
    private var panelBackground: some View {
        if showPanelBackground {
            let shape = RoundedRectangle(cornerRadius: isMist ? 20 : 14, style: .continuous)
            ZStack {
                if reduceTransparency {
                    shape.fill(palette.surface)
                } else if isMist {
                    shape.fill(.regularMaterial)
                    shape.fill(palette.surface.opacity(colorScheme == .dark ? 0.42 : 0.30))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(palette.surface.opacity(0.86))
                }
                shape.strokeBorder(palette.ink.opacity(palette.dark ? 0.13 : 0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(palette.dark ? 0.22 : 0.12), radius: isMist ? 10 : 16, y: isMist ? 4 : 7)
        }
    }
}
