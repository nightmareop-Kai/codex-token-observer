import AppKit
import SwiftUI

struct TokenSnapshot: Decodable {
    let today: Int64
    let total: Int64
    let projects: [ProjectSnapshot]?
    let quota: QuotaSnapshot?
    let profile: ZunoProfile?
    let leaderboard: LeaderboardSnapshot?
}

extension QuotaSnapshot {
    var tint: Color {
        guard let value = usedPercent else { return ObserverStyle.secondary }
        let green = (0.30, 0.78, 0.52)
        let yellow = (0.96, 0.78, 0.30)
        let red = (0.98, 0.35, 0.34)
        let start = value <= 60 ? green : yellow
        let end = value <= 60 ? yellow : red
        let t = value <= 60 ? value / 60 : (value - 60) / 40
        return Color(red: start.0 + (end.0 - start.0) * t,
                     green: start.1 + (end.1 - start.1) * t,
                     blue: start.2 + (end.2 - start.2) * t)
    }

}

struct ProjectSnapshot: Decodable, Identifiable {
    let name: String
    let path: String
    let total: Double
    let today: Double
    var id: String { path }
    var displayName: String { path.isEmpty ? "Unassigned" : name }
}

@MainActor
final class TokenModel: ObservableObject {
    // Visual prototype baseline only. Real usage remains separately persisted.
    static let visualTotalBaseline: Double = 1_208_604_730
    private static let refreshIntervalSeconds: Double = 300
    @Published var today: Double = 0
    @Published var total: Double = 0
    @Published var projects: [ProjectSnapshot] = []
    @Published var quota: QuotaSnapshot?
    @Published var profile: ZunoProfile?
    @Published var leaderboard = LeaderboardSnapshot()
    @Published var leaderboardOffset = 0
    @Published var leaderboardLoading = false
    @Published var profileBusy = false
    @Published var profileRequestError: String?
    var onNeedsProfile: (() -> Void)?
    private var promptedForProfile = false
    private let command = CollectorCommand.bundled()
    static let leaderboardPageSize = 50
    @Published var showAllProjects = false
    @Published var followsTargetApps = UserDefaults.standard.object(forKey: "followsTargetApps") as? Bool ?? true
    @Published var isConnected = false
    @Published var showPanelBackground = UserDefaults.standard.object(forKey: "showPanelBackground") as? Bool ?? true
    @Published var appearance = ObserverAppearance.load()
    @Published var demoTotalEnabled = UserDefaults.standard.bool(forKey: "demoTotalEnabled")
    private var process: Process?
    private var outputBuffer = Data()
    private var animationTask: Task<Void, Never>?
    private var demoPlaybackTask: Task<Void, Never>?
    private var hasAutoPlayedDemo = false
    private var lastRealToday: Double = 0
    private var lastRealTotal: Double = 0
    private var lastRealProjects: [ProjectSnapshot] = []

    func start() {
        guard process == nil else { return }
        try? FileManager.default.createDirectory(at: command.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let python = command.makeProcess(arguments: ["stream", "--interval", String(Self.refreshIntervalSeconds),
                                                      "--account-quota", "--leaderboard"])
        let pipe = Pipe()
        python.standardOutput = pipe
        python.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        python.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.isConnected = false; self?.process = nil }
        }
        do { try python.run(); process = python } catch { isConnected = false }
    }

    func stop() {
        animationTask?.cancel()
        demoPlaybackTask?.cancel()
        process?.terminate()
        process = nil
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard let snapshot = try? JSONDecoder().decode(TokenSnapshot.self, from: line) else { continue }
            quota = snapshot.quota
            if !profileBusy, let profile = snapshot.profile { receiveProfile(profile) }
            if let board = snapshot.leaderboard, !leaderboardLoading {
                if leaderboardOffset == 0 || board.date != leaderboard.date {
                    leaderboardOffset = 0
                    leaderboard = board
                }
            }
            lastRealToday = Double(snapshot.today)
            lastRealTotal = Double(snapshot.total)
            let displayedTotal = demoTotalEnabled
                ? Self.visualTotalBaseline + lastRealTotal
                : lastRealTotal
            let targetProjects = snapshot.projects ?? []
            lastRealProjects = targetProjects
            if !isConnected {
                today = Double(snapshot.today)
                total = displayedTotal
                projects = targetProjects
            } else {
                animationTask?.cancel()
                let oldProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
                let counterTargets = [Double(snapshot.today), displayedTotal]
                let counterValues = [today, total]
                var maximumDelta = zip(counterTargets, counterValues)
                    .map { max(0, $0 - $1) }
                    .max() ?? 0
                for project in targetProjects {
                    guard let oldProject = oldProjects[project.path] else { continue }
                    maximumDelta = max(
                        maximumDelta,
                        max(0, project.total - oldProject.total),
                        max(0, project.today - oldProject.today)
                    )
                }
                let duration = rollingDuration(for: maximumDelta)
                animationTask = Task { @MainActor in
                    if duration == 0 {
                        self.today = Double(snapshot.today)
                        self.total = displayedTotal
                        self.projects = targetProjects
                    } else {
                        // Skip the unreadable bulk of a large update, then roll a
                        // short tail. Decreases (including midnight) snap to zero.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.today = Self.stagedValue(self.today, toward: Double(snapshot.today))
                            self.total = Self.stagedValue(self.total, toward: displayedTotal)
                            self.projects = targetProjects.map { project in
                                guard let old = oldProjects[project.path] else { return project }
                                return ProjectSnapshot(name: project.name, path: project.path,
                                    total: Self.stagedValue(old.total, toward: project.total),
                                    today: Self.stagedValue(old.today, toward: project.today))
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(90))
                        guard !Task.isCancelled else { return }
                        withAnimation(.timingCurve(0.25, 0.50, 0.30, 1.0, duration: duration)) {
                            self.today = Double(snapshot.today)
                            self.total = displayedTotal
                            self.projects = targetProjects
                        }
                    }
                }
            }
            isConnected = true
            if demoTotalEnabled && !hasAutoPlayedDemo {
                hasAutoPlayedDemo = true
                demoPlaybackTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled else { return }
                    self.replayDualCounterDemo()
                }
            }
        }
    }

    private func receiveProfile(_ value: ZunoProfile) {
        profile = value
        if value.error == nil { profileRequestError = nil }
        if !promptedForProfile && !value.isRegistered {
            promptedForProfile = true
            onNeedsProfile?()
        }
    }

    func registerProfile(nickname: String) {
        guard !profileBusy, profile?.isRegistered != true,
              let name = ZunoProfile.normalizedNickname(nickname) else { return }
        performProfileCommand(["profile-register", "--nickname", name])
    }

    func toggleLeaderboardSync() {
        guard profile?.isRegistered == true else { return }
        performProfileCommand([profile?.isPaused == true ? "profile-resume" : "profile-pause"])
    }

    private func performProfileCommand(_ arguments: [String]) {
        guard !profileBusy else { return }
        profileBusy = true; profileRequestError = nil
        Task { @MainActor in
            let data = await command.run(arguments: arguments)
            defer { profileBusy = false }
            struct Reply: Decodable { let profile: ZunoProfile?; let error: String? }
            guard let data, let reply = try? JSONDecoder().decode(Reply.self, from: data), let profile = reply.profile else {
                profileRequestError = ZunoProfile.message(for: "offline")
                return
            }
            receiveProfile(profile)
            profileRequestError = ZunoProfile.message(for: reply.error ?? profile.error)
            if profile.isRegistered { refreshLeaderboard(offset: 0) }
        }
    }

    func refreshLeaderboard(offset: Int? = nil) {
        guard !leaderboardLoading else { return }
        let requestedOffset = max(0, offset ?? leaderboardOffset)
        leaderboardLoading = true
        Task { @MainActor in
            let data = await command.run(arguments: ["leaderboard-read", "--offset", String(requestedOffset),
                                                       "--limit", String(Self.leaderboardPageSize)])
            defer { leaderboardLoading = false }
            guard let data, let board = try? JSONDecoder().decode(LeaderboardSnapshot.self, from: data) else {
                leaderboard = leaderboard.asOffline(); return
            }
            if board.status == "ok" {
                leaderboard = board; leaderboardOffset = requestedOffset
            } else if leaderboard.entries.isEmpty {
                leaderboard = board
            } else {
                leaderboard = leaderboard.asOffline()
            }
        }
    }

    private func stage(_ displayed: inout Double, toward target: Double) {
        displayed = Self.stagedValue(displayed, toward: target)
    }

    static func stagedValue(_ current: Double, toward target: Double) -> Double {
        if target < current { return target }
        return max(current, target - 48)
    }

    private func rollingDuration(for delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        // A brief fast-to-slow burst on each sample; no rendering while idle.
        return min(4.5, 3.0 + log10(max(1, delta)) * 0.25)
    }

    func toggleDemoTotal() {
        animationTask?.cancel()
        demoPlaybackTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            today = lastRealToday
            projects = lastRealProjects
        }
        demoTotalEnabled.toggle()
        UserDefaults.standard.set(demoTotalEnabled, forKey: "demoTotalEnabled")
        let target = demoTotalEnabled
            ? Self.visualTotalBaseline + lastRealTotal
            : lastRealTotal
        if target < total {
            withTransaction(transaction) { total = target }
            return
        }
        stage(&total, toward: target)
        withAnimation(.timingCurve(0.25, 0.50, 0.30, 1.0, duration: 4.5)) {
            total = target
        }
    }

    func replayDualCounterDemo() {
        guard demoTotalEnabled else { return }
        animationTask?.cancel()
        demoPlaybackTask?.cancel()
        projects = lastRealProjects
        let totalTarget = Self.visualTotalBaseline + lastRealTotal
        today = max(0, lastRealToday - 48)
        total = max(0, totalTarget - 48)
        demoPlaybackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.25, 0.50, 0.30, 1.0, duration: 4.5)) {
                self.today = self.lastRealToday
                self.total = totalTarget
            }
        }
    }
}

struct OdometerDigit: View {
    let value: Double
    let place: Double
    let size: CGFloat
    let active: Bool
    var tint: Color = ObserverStyle.accent
    var appearance: ObserverAppearance = .classic
    var zeroTint: Color = ObserverStyle.zero

    private var wheelPosition: Double {
        let safeValue = max(0, value)
        if place == 1 { return safeValue }
        let completed = floor(safeValue / place)
        let remainder = safeValue.truncatingRemainder(dividingBy: place)
        // A higher wheel moves only during the final single-unit interval before
        // a real carry. At every integer resting value it lands on a full cell.
        let carry = max(0, min(1, remainder - (place - 1)))
        return completed + carry
    }
    private var lowerDigit: Int { Int(floor(wheelPosition)) % 10 }
    private var progress: Double { wheelPosition - floor(wheelPosition) }
    private var upperDigit: Int { (lowerDigit + 1) % 10 }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: 0) {
                digitText(lowerDigit).frame(height: height)
                digitText(upperDigit).frame(height: height)
            }
            .offset(y: -CGFloat(progress) * height)
        }
        .frame(width: size * appearance.digitWidth, height: size * 1.18)
        .clipped()
    }

    private func digitText(_ digit: Int) -> some View {
        Text(String(digit))
            .font(appearance.digitFont(size: size))
            .monospacedDigit()
            .foregroundStyle(active ? tint : zeroTint)
            .shadow(color: appearance == .classic ? Color.black.opacity(0.72) : .clear, radius: 1.4, y: 0.7)
            .shadow(color: appearance == .classic && active ? tint.opacity(0.12) : .clear, radius: 4)
    }
}

struct RollingNumber: View, Animatable {
    var value: Double
    let size: CGFloat
    var tint: Color = ObserverStyle.accent
    var minimumDigits: Int = 12
    var appearance: ObserverAppearance = .classic
    var zeroTint: Color = ObserverStyle.zero

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let numericText = String(Int64(max(0, value)))
            let activeDigits = max(1, numericText.count)
            let count = max(minimumDigits, activeDigits)
            let widthInEm = CGFloat(count) * appearance.digitWidth + CGFloat((count - 1) / 3) * appearance.groupSpacing
            let fittedSize = min(size, max(1, geometry.size.width) / widthInEm)
            let firstActiveIndex = max(0, count - activeDigits)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 && (count - index).isMultiple(of: 3) {
                        Spacer().frame(width: fittedSize * appearance.groupSpacing)
                    }
                    OdometerDigit(
                        value: value,
                        place: pow(10.0, Double(count - 1 - index)),
                        size: fittedSize,
                        active: index >= firstActiveIndex,
                        tint: tint, appearance: appearance, zeroTint: zeroTint
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(height: size * 1.18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int64(value)) tokens")
    }
}

enum ObserverStyle {
    static let accent = Color(red: 0.40, green: 0.86, blue: 0.95)
    static let silver = Color(red: 0.78, green: 0.84, blue: 0.90)
    static let secondary = Color(red: 0.60, green: 0.67, blue: 0.73)
    static let zero = Color(red: 0.48, green: 0.55, blue: 0.62).opacity(0.42)
    static let bodyWidth: CGFloat = 276
    static let outerPadding: CGFloat = 12
    static let compactProjectHeight: CGFloat = 78
    static let expandedProjectHeight: CGFloat = 222
}

struct CounterRow: View {
    let label: String
    let value: Double
    let primary: Bool
    var warningTint: Color?
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
                .tracking(1.8)
                .foregroundStyle(primary ? ObserverStyle.accent.opacity(0.85) : ObserverStyle.secondary)
                .shadow(color: Color.black.opacity(0.78), radius: 1.4, y: 0.7)
                .frame(width: 36, alignment: .leading)
            RollingNumber(value: value, size: primary ? 20 : 16, tint: warningTint ?? (primary ? ObserverStyle.accent : ObserverStyle.silver))
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ProjectRow: View {
    let rank: Int
    let project: ProjectSnapshot
    var warningTint: Color?
    var showToday = true
    var showTotal = true

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(String(format: "%02d", rank))
                .font(.custom("Avenir Next Condensed", size: 9).weight(.medium))
                .foregroundStyle(ObserverStyle.secondary.opacity(0.65))
                .frame(width: 11, alignment: .leading)
            Text(project.displayName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(2)
                .truncationMode(.tail)
                .lineSpacing(2)
                .foregroundStyle(ObserverStyle.silver)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(project.path.isEmpty ? "Project directory not identified." : "\(project.name)\n\(project.path)")
            VStack(spacing: 3) {
                if showToday { metric(label: "TODAY", value: project.today, isToday: true) }
                if showTotal { metric(label: "TOTAL", value: project.total, isToday: false) }
            }
            .frame(width: 132)
        }
        .frame(height: showToday && showTotal ? 30 : 22)
        .shadow(color: Color.black.opacity(0.72), radius: 1.2, y: 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today rank \(rank), \(project.displayName)"
            + (showToday ? ", today \(Int64(project.today)) tokens" : "")
            + (showTotal ? ", total \(Int64(project.total)) tokens" : ""))
    }

    private func metric(label: String, value: Double, isToday: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.custom("Avenir Next Condensed", size: 7).weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(isToday ? ObserverStyle.accent.opacity(0.70) : ObserverStyle.secondary.opacity(0.78))
                .frame(width: 28, alignment: .leading)
            RollingNumber(value: value, size: 11, tint: warningTint ?? (isToday ? ObserverStyle.accent : ObserverStyle.silver.opacity(0.85)))
        }
    }
}

struct WeeklyQuotaRow: View {
    let quota: QuotaSnapshot?

    private var tint: Color { quota?.tint ?? ObserverStyle.secondary }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("WEEKLY REMAINING")
                    .font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(ObserverStyle.secondary)
                if quota?.stale == true {
                    Text("STALE").font(.system(size: 7)).foregroundStyle(ObserverStyle.secondary)
                }
                Spacer()
                if let percent = quota?.remainingPercent {
                    Text(String(format: "%.0f%%", percent))
                        .font(.custom("Avenir Next Condensed", size: 11).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                } else {
                    Text("—").font(.system(size: 12)).foregroundStyle(ObserverStyle.secondary)
                }
            }
            .frame(height: 14)
            GeometryReader { geometry in
                Capsule().fill(ObserverStyle.secondary.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * ((quota?.remainingPercent ?? 0) / 100))
                    .shadow(color: tint.opacity(0.15), radius: 3)
            }
            .frame(height: 2)
        }
        .help(quota?.detail ?? "Reading weekly account allowance…")
        .accessibilityElement(children: .combine)
    }
}

// The same view is used by the floating window and the offline layout preview.
struct ObserverContent: View {
    let today: Double
    let total: Double
    let projects: [ProjectSnapshot]
    let isConnected: Bool
    let showPanelBackground: Bool
    var glow = false
    var quota: QuotaSnapshot?
    var showAllProjects = false
    var appearance: ObserverAppearance = .classic
    var onToggleProjects: () -> Void = {}
    var onSelectAppearance: (ObserverAppearance) -> Void = { _ in }
    var page: ObserverPage = .counter
    var leaderboardSnapshot = LeaderboardSnapshot()
    var profile: ZunoProfile?
    var leaderboardOffset = 0
    var leaderboardLoading = false
    var onRefreshLeaderboard: () -> Void = {}
    var onLeaderboardPage: (Int) -> Void = { _ in }
    var onProfile: () -> Void = {}
    var onTogglePage: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var projectsHovered = false

    private var warningTint: Color? { quota?.isExhausted == true ? quota?.tint : nil }

    private var visibleProjects: [ProjectSnapshot] { showAllProjects ? projects : Array(projects.prefix(3)) }

    var body: some View {
        Group {
            if appearance == .mist {
                MistObserverContent(today: today, total: total, projects: projects,
                                    isConnected: isConnected, showPanelBackground: showPanelBackground,
                                    quota: quota, showAllProjects: showAllProjects,
                                    onToggleProjects: onToggleProjects, onSelectAppearance: onSelectAppearance)
            } else {
                classicContent
            }
        }
        .environment(\.locale, Locale(identifier: "en"))
        // Counter stays mounted and determines both pages' footprint.
        .opacity(page == .counter ? 1 : 0)
        .allowsHitTesting(page == .counter)
        .accessibilityHidden(page != .counter)
        .environment(\.pageInteractionsEnabled, page == .counter)
        .overlay {
            if page == .leaderboard {
                GeometryReader { geometry in
                    LeaderboardContent(snapshot: leaderboardSnapshot, appearance: appearance,
                                       showPanelBackground: showPanelBackground,
                                       onBack: onTogglePage, onSelectAppearance: onSelectAppearance,
                                       profile: profile, offset: leaderboardOffset,
                                       loading: leaderboardLoading, onRefresh: onRefreshLeaderboard,
                                       onPage: onLeaderboardPage, onProfile: onProfile)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: page)
    }

    private var classicContent: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 6) {
                Text("ZUNO")
                    .foregroundStyle(ObserverStyle.silver.opacity(0.9))
                Text("/  TOKEN COUNTER")
                    .foregroundStyle(ObserverStyle.secondary.opacity(0.75))
                Spacer()
                Circle().fill(isConnected ? ObserverStyle.accent : Color.orange)
                    .frame(width: 4, height: 4)
                    .shadow(color: ObserverStyle.accent.opacity(glow ? 0.45 : 0.15), radius: glow ? 5 : 2)
                Text(isConnected ? "LIVE" : "SYNC")
                    .foregroundStyle(ObserverStyle.secondary)
                AppearanceMenu(appearance: .classic, tint: ObserverStyle.secondary, onSelect: onSelectAppearance)
            }
            .font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
            .tracking(1.1)
            .padding(.bottom, 8)

            WeeklyQuotaRow(quota: quota)
                .padding(.bottom, 9)

            VStack(spacing: 4) {
                CounterRow(label: "TODAY", value: today, primary: true, warningTint: warningTint)
                CounterRow(label: "TOTAL", value: total, primary: false, warningTint: warningTint)
            }
            .padding(.bottom, 9)

            Rectangle()
                .fill(LinearGradient(colors: [ObserverStyle.secondary.opacity(0.05), ObserverStyle.secondary.opacity(0.30)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)

            Button(action: onToggleProjects) {
                HStack(spacing: 5) {
                    Text(showAllProjects ? "PROJECTS / ALL" : "PROJECTS / TODAY")
                        .font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
                        .tracking(1.1)
                    Spacer()
                    Text(showAllProjects ? "COLLAPSE · \(projects.count)" : "ALL \(projects.count)")
                        .font(.system(size: 8))
                    Image(systemName: showAllProjects ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(projectsHovered ? ObserverStyle.accent : ObserverStyle.secondary.opacity(0.85))
                .contentShape(Rectangle())
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .onHover { projectsHovered = $0 }
            .help(showAllProjects ? "Ranked by today's usage. Click to show only the top three." : "Show all projects, ranked by today's usage.")
            .accessibilityLabel(showAllProjects ? "Collapse project list" : "Show all \(projects.count) projects")
            .background(PageInteractionExclusion())

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(visibleProjects.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(rank: index + 1, project: project, warningTint: warningTint,
                                   showToday: index < 3, showTotal: showAllProjects)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(showAllProjects ? .automatic : .hidden)
            .scrollDisabled(!showAllProjects)
            .frame(height: showAllProjects ? ObserverStyle.expandedProjectHeight : ObserverStyle.compactProjectHeight)
            .background(PageInteractionExclusion())
            .overlay {
                if projects.isEmpty {
                    Text(isConnected ? "Waiting for project activity" : "Reading local activity…")
                        .font(.system(size: 10))
                        .foregroundStyle(ObserverStyle.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .frame(width: ObserverStyle.bodyWidth)
        .shadow(color: Color.black.opacity(0.6), radius: 1, y: 0.5)
        .background {
            if showPanelBackground {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: 0.025, green: 0.045, blue: 0.065).opacity(0.86))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(LinearGradient(colors: [ObserverStyle.silver.opacity(0.18), ObserverStyle.silver.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                }.shadow(color: Color.black.opacity(0.26), radius: 16, y: 7)
            }
        }
        .padding(ObserverStyle.outerPadding)
        .colorScheme(.dark)
        .environment(\.locale, Locale(identifier: "en"))
    }
}

struct ObserverView: View {
    @ObservedObject var model: TokenModel
    @ObservedObject var navigation: PanelNavigation
    let onHide: () -> Void
    let onProjectsExpanded: (Bool) -> Void
    let onToggleFollowing: () -> Void
    let onSelectAppearance: (ObserverAppearance) -> Void
    let onTogglePage: () -> Void
    let onProfile: () -> Void

    var body: some View {
        ObserverContent(today: model.today, total: model.total, projects: model.projects,
                        isConnected: model.isConnected, showPanelBackground: model.showPanelBackground,
                        quota: model.quota, showAllProjects: model.showAllProjects, appearance: model.appearance,
                        onToggleProjects: {
                            model.showAllProjects.toggle()
                            onProjectsExpanded(model.showAllProjects)
                        }, onSelectAppearance: onSelectAppearance,
                        page: navigation.page, leaderboardSnapshot: model.leaderboard,
                        profile: model.profile, leaderboardOffset: model.leaderboardOffset,
                        leaderboardLoading: model.leaderboardLoading,
                        onRefreshLeaderboard: { model.refreshLeaderboard() },
                        onLeaderboardPage: { model.refreshLeaderboard(offset: $0) }, onProfile: onProfile,
                        onTogglePage: onTogglePage)
        .contentShape(Rectangle())
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            model.refreshLeaderboard(offset: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            model.refreshLeaderboard(offset: 0)
        }
        .contextMenu {
            Button(navigation.page.switchTitle, action: onTogglePage)
            Button("Your Zuno profile", action: onProfile)
            if model.profile?.isRegistered == true {
                Button(model.profile?.isPaused == true ? "Resume leaderboard sync" : "Pause leaderboard sync") {
                    model.toggleLeaderboardSync()
                }.disabled(model.profileBusy)
            }
            Divider()
            Button("Hide Window", action: onHide)
            Menu("Appearance") {
                AppearanceOptions(appearance: model.appearance, onSelect: onSelectAppearance)
            }
            Toggle("Follow Codex / ChatGPT", isOn: Binding(
                get: { model.followsTargetApps },
                set: { _ in onToggleFollowing() }
            ))
        }
    }
}

enum Corner: String { case left, right }

struct ProfileWindowContent: View {
    @ObservedObject var model: TokenModel
    let onClose: () -> Void
    var body: some View {
        ProfileContent(profile: model.profile, busy: model.profileBusy,
                       requestError: model.profileRequestError,
                       onRegister: model.registerProfile, onToggleSync: model.toggleLeaderboardSync,
                       onClose: onClose)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TokenModel()
    private let navigation = PanelNavigation()
    private var pageGesture: PanelPageGesture?
    private var pageItems: [NSMenuItem] = []
    private var profileWindow: NSWindow?
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var visibilityItems: [NSMenuItem] = []
    private var backgroundItems: [NSMenuItem] = []
    private var demoItems: [NSMenuItem] = []
    private var followItems: [NSMenuItem] = []
    private var appearanceItems: [NSMenuItem] = []
    private var foregroundPolicy: ForegroundPolicy?
    private var targetAppIsForeground = false
    private var compactPanelSize = NSSize.zero
    private var resizingPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ObserverPreview.runIfRequested() { NSApp.terminate(nil); return }
        #endif
        // Keep the compact panel, but expose a normal app entry in the Dock
        // and Command-Tab so a hidden observer can always be found again.
        NSApp.setActivationPolicy(.regular)
        model.onNeedsProfile = { [weak self] in self?.showProfile() }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 280),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Zuno"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.delegate = self
        let contentView = NSHostingView(rootView: ObserverView(model: model, navigation: navigation, onHide: { [weak self] in
            self?.hidePanel()
        }, onProjectsExpanded: { [weak self] expanded in
            self?.resizeProjectList(expanded: expanded)
        }, onToggleFollowing: { [weak self] in
            self?.toggleForegroundFollowing()
        }, onSelectAppearance: { [weak self] appearance in
            self?.selectAppearance(appearance)
        }, onTogglePage: { [weak self] in
            self?.togglePage()
        }, onProfile: { [weak self] in
            self?.showProfile()
        }))
        panel.contentView = contentView
        pageGesture = PanelPageGesture(host: contentView) { [weak self] in self?.togglePage() }
        compactPanelSize = contentView.fittingSize
        contentView.sizingOptions = []
        panel.setContentSize(compactPanelSize)
        panel.orderFrontRegardless()
        move(to: Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "right") ?? .right)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "number.square", accessibilityDescription: "Zuno")
        statusItem.button?.toolTip = "Zuno"
        statusItem.menu = makeMenu()
        panel.contentView?.menu = makeMenu()
        updateMenuState()
        foregroundPolicy = ForegroundPolicy { [weak self] shouldFloat in
            guard let self else { return }
            self.targetAppIsForeground = shouldFloat
            self.applyForegroundPolicy()
        }
        foregroundPolicy?.start()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        pageItems.append(addItem(to: menu, title: navigation.page.switchTitle, action: #selector(togglePage)))
        addItem(to: menu, title: "Your Zuno profile", action: #selector(showProfile))
        menu.addItem(.separator())
        let visibilityItem = addItem(to: menu, title: "Hide Window", action: #selector(togglePanelVisibility))
        visibilityItems.append(visibilityItem)
        let appearanceMenu = NSMenu()
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        for appearance in ObserverAppearance.allCases {
            let item = addItem(to: appearanceMenu, title: appearance.title, action: #selector(selectAppearanceItem))
            item.representedObject = appearance.rawValue
            appearanceItems.append(item)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Move to Bottom Left", action: #selector(moveLeft))
        addItem(to: menu, title: "Move to Bottom Right", action: #selector(moveRight))
        let backgroundItem = addItem(to: menu, title: "Show Translucent Background", action: #selector(toggleBackground))
        backgroundItems.append(backgroundItem)
        let followItem = addItem(to: menu, title: "Follow Codex / ChatGPT", action: #selector(toggleForegroundFollowing))
        followItems.append(followItem)
        let demoItem = addItem(to: menu, title: "Add Demo Baseline", action: #selector(toggleDemoTotal))
        demoItems.append(demoItem)
        addItem(to: menu, title: "Replay Counter Animation", action: #selector(replayDualDemo))
        menu.addItem(.separator())
        addItem(to: menu, title: "Quit Zuno", action: #selector(quit), keyEquivalent: "q")
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    func applicationWillTerminate(_ notification: Notification) {
        pageGesture?.stop()
        foregroundPolicy?.stop()
        model.stop()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard panel != nil else { return false }
        showPanel()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if navigation.page == .leaderboard { model.refreshLeaderboard() }
        // Activation may follow a Dock click. Raise a visible panel without
        // undoing an explicit Hide Window merely because our menu activates.
        guard panel?.isVisible == true else { return }
        panel.orderFrontRegardless()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding/closing the widget must not terminate background collection.
        false
    }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addItem(to: menu, title: "Show Window", action: #selector(showPanel))
        if panel?.isVisible == true {
            addItem(to: menu, title: "Hide Window", action: #selector(hidePanel))
        }
        return menu
    }
    @objc private func showPanel() {
        guard panel != nil else { return }
        NSApp.unhide(nil)
        panel.orderFrontRegardless()
        updateMenuState()
    }
    @objc private func togglePage() {
        navigation.toggle()
        if navigation.page == .leaderboard { model.refreshLeaderboard(offset: 0) }
        updateMenuState()
    }
    @objc private func showProfile() {
        if let window = profileWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Your Zuno profile"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: ProfileWindowContent(model: model, onClose: { [weak window] in window?.close() }))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        profileWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func togglePanelVisibility() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }
    @objc private func hidePanel() {
        panel.orderOut(nil)
        updateMenuState()
    }
    @objc private func moveLeft() { move(to: .left) }
    @objc private func moveRight() { move(to: .right) }
    @objc private func selectAppearanceItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let appearance = ObserverAppearance(rawValue: raw) else { return }
        selectAppearance(appearance)
    }
    private func selectAppearance(_ appearance: ObserverAppearance) {
        guard model.appearance != appearance else { return }
        model.appearance = appearance
        appearance.save()
        // Measure only the presentation. A style switch never restarts the
        // collector or changes its published counters, expansion, or visibility.
        let measurement = NSHostingView(rootView: ObserverContent(
            today: model.today, total: model.total, projects: model.projects,
            isConnected: model.isConnected, showPanelBackground: model.showPanelBackground,
            quota: model.quota, appearance: appearance))
        compactPanelSize = measurement.fittingSize
        resizeProjectList(expanded: model.showAllProjects, animated: false)
        updateMenuState()
    }
    @objc private func toggleBackground(_ sender: NSMenuItem) {
        model.showPanelBackground.toggle()
        UserDefaults.standard.set(model.showPanelBackground, forKey: "showPanelBackground")
        updateMenuState()
    }
    @objc private func toggleDemoTotal(_ sender: NSMenuItem) {
        model.toggleDemoTotal()
        updateMenuState()
    }
    @objc private func toggleForegroundFollowing() {
        model.followsTargetApps.toggle()
        UserDefaults.standard.set(model.followsTargetApps, forKey: "followsTargetApps")
        applyForegroundPolicy()
        updateMenuState()
    }

    private func applyForegroundPolicy() {
        let shouldFloat = !model.followsTargetApps || targetAppIsForeground
        let wasVisible = panel.isVisible
        panel.level = shouldFloat ? .floating : .normal
        // App switches never undo a deliberate hide or steal keyboard focus.
        if wasVisible {
            if shouldFloat { panel.orderFrontRegardless() }
            else { panel.orderBack(nil) }
        }
    }
    @objc private func replayDualDemo() { model.replayDualCounterDemo() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateMenuState() {
        pageItems.forEach { $0.title = navigation.page.switchTitle }
        visibilityItems.forEach { $0.title = panel.isVisible ? "Hide Window" : "Show Window" }
        backgroundItems.forEach { $0.state = model.showPanelBackground ? .on : .off }
        demoItems.forEach { $0.state = model.demoTotalEnabled ? .on : .off }
        followItems.forEach { $0.state = model.followsTargetApps ? .on : .off }
        appearanceItems.forEach { $0.state = ($0.representedObject as? String) == model.appearance.rawValue ? .on : .off }
    }

    private func resizeProjectList(expanded: Bool, animated: Bool = true) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let oldFrame = panel.frame
        let extraHeight = expanded ? ObserverStyle.expandedProjectHeight - ObserverStyle.compactProjectHeight : 0
        let height = min(visible.height - 6, compactPanelSize.height + extraHeight)
        let topAnchored = abs(oldFrame.maxY - visible.maxY) < 26
        let y = topAnchored ? visible.maxY - height - 3 : min(oldFrame.minY, visible.maxY - height - 3)
        let rightAnchored = abs(oldFrame.maxX - visible.maxX) < 26
        let x = rightAnchored ? visible.maxX - compactPanelSize.width - 3 : oldFrame.minX
        let target = NSRect(x: x, y: max(visible.minY + 3, y), width: compactPanelSize.width, height: height)
        resizingPanel = true
        if !animated {
            panel.setFrame(target, display: true)
            resizingPanel = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.resizingPanel = false }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !resizingPanel else { return }
        snapToVisibleEdge()
    }

    private func snapToVisibleEdge() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        let threshold: CGFloat = 26
        let margin: CGFloat = 3
        if abs(panel.frame.minX - visible.minX) < threshold { origin.x = visible.minX + margin }
        if abs(panel.frame.maxX - visible.maxX) < threshold { origin.x = visible.maxX - panel.frame.width - margin }
        if abs(panel.frame.minY - visible.minY) < threshold { origin.y = visible.minY + margin }
        if abs(panel.frame.maxY - visible.maxY) < threshold { origin.y = visible.maxY - panel.frame.height - margin }
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    private func move(to corner: Corner) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame, margin: CGFloat = 3
        let x = corner == .right ? frame.maxX - panel.frame.width - margin : frame.minX + margin
        panel.setFrameOrigin(NSPoint(x: x, y: frame.minY + margin))
        UserDefaults.standard.set(corner.rawValue, forKey: "corner")
    }
}

@main
struct CodexTokenObserverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}
