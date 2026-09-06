import AppKit
import SwiftUI

struct TokenSnapshot: Decodable {
    let today: Int64
    let total: Int64
    let projects: [ProjectSnapshot]?
    let quota: QuotaSnapshot?
}

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

    var percent: Double? { available || stale ? cumulativePercent : nil }
    var isOverLimit: Bool { (percent ?? 0) >= 100 }

    var tint: Color {
        guard let percent else { return ObserverStyle.secondary }
        let value = max(0, min(100, percent))
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

    var detail: String {
        guard let currentPercent, let percent else { return "Waiting for weekly usage. Sign in to Codex to view your account quota." }
        var detail = "Main Codex account weekly usage. Current window: \(String(format: "%.0f", currentPercent))%. Cumulative usage including observed resets: \(String(format: "%.0f", percent))%."
        if estimated { detail += " Usage before a reset is estimated from the last sample; activity between samples may be missed." }
        detail += " Earlier resets are not included. Cumulative usage restarts when the weekly window expires."
        if let resetsAt {
            let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_US"))
            detail += " Window ends: \(Date(timeIntervalSince1970: resetsAt).formatted(dateStyle))."
        }
        if stale { detail += " Showing the last available reading while waiting for an update." }
        return detail
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
    @Published var showAllProjects = false
    @Published var followsTargetApps = UserDefaults.standard.object(forKey: "followsTargetApps") as? Bool ?? true
    @Published var isConnected = false
    @Published var showPanelBackground = UserDefaults.standard.bool(forKey: "showPanelBackground")
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
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let resources = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/counter")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Token Observer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let database = support.appendingPathComponent("token_counter.sqlite3")
        let python = Process()
        let pipe = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.currentDirectoryURL = resources
        python.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONPATH": resources.appendingPathComponent("src").path,
            "PYTHONUNBUFFERED": "1"
        ]) { _, new in new }
        python.arguments = ["-m", "codex_token_counter.cli", "--db",
                            database.path,
                            "stream", "--interval", String(Self.refreshIntervalSeconds), "--account-quota"]
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
        .frame(width: size * 0.52, height: size * 1.18)
        .clipped()
    }

    private func digitText(_ digit: Int) -> some View {
        Text(String(digit))
            .font(.custom("Avenir Next Condensed", size: size).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(active ? tint : ObserverStyle.zero)
            .shadow(color: Color.black.opacity(0.72), radius: 1.4, y: 0.7)
            .shadow(color: active ? tint.opacity(0.12) : .clear, radius: 4)
    }
}

struct RollingNumber: View, Animatable {
    var value: Double
    let size: CGFloat
    var tint: Color = ObserverStyle.accent
    var minimumDigits: Int = 12

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let numericText = String(Int64(max(0, value)))
            let activeDigits = max(1, numericText.count)
            let count = max(minimumDigits, activeDigits)
            let widthInEm = CGFloat(count) * 0.52 + CGFloat((count - 1) / 3) * 0.28
            let fittedSize = min(size, max(1, geometry.size.width) / widthInEm)
            let firstActiveIndex = max(0, count - activeDigits)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 && (count - index).isMultiple(of: 3) {
                        Spacer().frame(width: fittedSize * 0.28)
                    }
                    OdometerDigit(
                        value: value,
                        place: pow(10.0, Double(count - 1 - index)),
                        size: fittedSize,
                        active: index >= firstActiveIndex,
                        tint: tint
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
                Text("WEEKLY USAGE")
                    .font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(ObserverStyle.secondary)
                if quota?.stale == true {
                    Text("STALE").font(.system(size: 7)).foregroundStyle(ObserverStyle.secondary)
                }
                Spacer()
                if let percent = quota?.percent {
                    Text((quota?.estimated == true ? "≈ " : "") + String(format: "%.0f%%", percent))
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
                    .frame(width: geometry.size.width * min(1, max(0, (quota?.percent ?? 0) / 100)))
                    .shadow(color: tint.opacity(0.15), radius: 3)
            }
            .frame(height: 2)
        }
        .help(quota?.detail ?? "Reading weekly account usage…")
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
    var onToggleProjects: () -> Void = {}
    @State private var projectsHovered = false

    private var warningTint: Color? { quota?.isOverLimit == true ? quota?.tint : nil }

    private var visibleProjects: [ProjectSnapshot] { showAllProjects ? projects : Array(projects.prefix(3)) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 6) {
                Text("CODEX")
                    .foregroundStyle(ObserverStyle.silver.opacity(0.9))
                Text("/  TOKEN OBSERVER")
                    .foregroundStyle(ObserverStyle.secondary.opacity(0.75))
                Spacer()
                Circle().fill(isConnected ? ObserverStyle.accent : Color.orange)
                    .frame(width: 4, height: 4)
                    .shadow(color: ObserverStyle.accent.opacity(glow ? 0.45 : 0.15), radius: glow ? 5 : 2)
                Text(isConnected ? "LIVE" : "SYNC")
                    .foregroundStyle(ObserverStyle.secondary)
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
    let onHide: () -> Void
    let onProjectsExpanded: (Bool) -> Void
    let onToggleFollowing: () -> Void

    var body: some View {
        ObserverContent(today: model.today, total: model.total, projects: model.projects,
                        isConnected: model.isConnected, showPanelBackground: model.showPanelBackground,
                        quota: model.quota, showAllProjects: model.showAllProjects,
                        onToggleProjects: {
                            model.showAllProjects.toggle()
                            onProjectsExpanded(model.showAllProjects)
                        })
        .contentShape(Rectangle())
        .onAppear { model.start() }
        .contextMenu {
            Button("Hide Window", action: onHide)
            Toggle("Follow Codex / ChatGPT", isOn: Binding(
                get: { model.followsTargetApps },
                set: { _ in onToggleFollowing() }
            ))
        }
    }
}

enum Corner: String { case left, right }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TokenModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var visibilityItems: [NSMenuItem] = []
    private var backgroundItems: [NSMenuItem] = []
    private var demoItems: [NSMenuItem] = []
    private var followItems: [NSMenuItem] = []
    private var foregroundPolicy: ForegroundPolicy?
    private var targetAppIsForeground = false
    private var compactPanelSize = NSSize.zero
    private var resizingPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ObserverPreview.runIfRequested() { NSApp.terminate(nil); return }
        #endif
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 280),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.delegate = self
        let contentView = NSHostingView(rootView: ObserverView(model: model, onHide: { [weak self] in
            self?.hidePanel()
        }, onProjectsExpanded: { [weak self] expanded in
            self?.resizeProjectList(expanded: expanded)
        }, onToggleFollowing: { [weak self] in
            self?.toggleForegroundFollowing()
        }))
        panel.contentView = contentView
        compactPanelSize = contentView.fittingSize
        contentView.sizingOptions = []
        panel.setContentSize(compactPanelSize)
        panel.orderFrontRegardless()
        move(to: Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "right") ?? .right)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "number.square", accessibilityDescription: "Token Observer")
        statusItem.button?.toolTip = "Codex Token Observer"
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
        let visibilityItem = addItem(to: menu, title: "Hide Window", action: #selector(togglePanelVisibility))
        visibilityItems.append(visibilityItem)
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
        addItem(to: menu, title: "Quit Token Observer", action: #selector(quit), keyEquivalent: "q")
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    func applicationWillTerminate(_ notification: Notification) {
        foregroundPolicy?.stop()
        model.stop()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard panel != nil else { return false }
        panel.orderFrontRegardless()
        updateMenuState()
        return false
    }
    @objc private func togglePanelVisibility() {
        if panel.isVisible {
            hidePanel()
        } else {
            panel.orderFrontRegardless()
            updateMenuState()
        }
    }
    private func hidePanel() {
        panel.orderOut(nil)
        updateMenuState()
    }
    @objc private func moveLeft() { move(to: .left) }
    @objc private func moveRight() { move(to: .right) }
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
        visibilityItems.forEach { $0.title = panel.isVisible ? "Hide Window" : "Show Window" }
        backgroundItems.forEach { $0.state = model.showPanelBackground ? .on : .off }
        demoItems.forEach { $0.state = model.demoTotalEnabled ? .on : .off }
        followItems.forEach { $0.state = model.followsTargetApps ? .on : .off }
    }

    private func resizeProjectList(expanded: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let oldFrame = panel.frame
        let extraHeight = expanded ? ObserverStyle.expandedProjectHeight - ObserverStyle.compactProjectHeight : 0
        let height = min(visible.height - 6, compactPanelSize.height + extraHeight)
        let topAnchored = abs(oldFrame.maxY - visible.maxY) < 26
        let y = topAnchored ? visible.maxY - height - 3 : min(oldFrame.minY, visible.maxY - height - 3)
        let target = NSRect(x: oldFrame.minX, y: max(visible.minY + 3, y), width: compactPanelSize.width, height: height)
        resizingPanel = true
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
