import AppKit
import SwiftUI

struct TokenSnapshot: Decodable {
    let today: Int64
    let total: Int64
}

@MainActor
final class TokenModel: ObservableObject {
    // Visual prototype baseline only. Real usage remains separately persisted.
    static let visualTotalBaseline: Double = 1_208_604_730
    @Published var today: Double = 0
    @Published var total: Double = 0
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
                            "stream", "--interval", "0.4"]
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
            lastRealToday = Double(snapshot.today)
            lastRealTotal = Double(snapshot.total)
            let displayedTotal = demoTotalEnabled
                ? Self.visualTotalBaseline + lastRealTotal
                : lastRealTotal
            if !isConnected {
                today = Double(snapshot.today)
                total = displayedTotal
            } else {
                animationTask?.cancel()
                stage(&today, toward: Double(snapshot.today))
                stage(&total, toward: displayedTotal)
                animationTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled else { return }
                    withAnimation(.timingCurve(0.18, 0.72, 0.22, 1.0, duration: 3.1)) {
                        self.today = Double(snapshot.today)
                        self.total = displayedTotal
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
        let delta = max(0, target - displayed)
        // Real Codex updates can contain hundreds of thousands of tokens. Showing
        // every unit would make the wheel strobe, so preserve only a readable tail.
        if delta > 12 { displayed = target - 12 }
    }

    func toggleDemoTotal() {
        demoTotalEnabled.toggle()
        UserDefaults.standard.set(demoTotalEnabled, forKey: "demoTotalEnabled")
        let target = demoTotalEnabled
            ? Self.visualTotalBaseline + lastRealTotal
            : lastRealTotal
        if target < total {
            total = target
            return
        }
        stage(&total, toward: target)
        withAnimation(.timingCurve(0.18, 0.72, 0.22, 1.0, duration: 3.1)) {
            total = target
        }
    }

    func replayDualCounterDemo() {
        guard demoTotalEnabled else { return }
        animationTask?.cancel()
        demoPlaybackTask?.cancel()
        let totalTarget = Self.visualTotalBaseline + lastRealTotal
        today = max(0, lastRealToday - 12)
        total = max(0, totalTarget - 12)
        demoPlaybackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.18, 0.72, 0.22, 1.0, duration: 3.1)) {
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
            .foregroundStyle(active ? Color.cyan.opacity(0.96) : Color.gray.opacity(0.48))
            .shadow(color: Color.black.opacity(0.72), radius: 1.4, y: 0.7)
            .shadow(color: active ? Color.cyan.opacity(0.20) : .clear, radius: 7)
    }
}

struct RollingNumber: View, Animatable {
    var value: Double
    let size: CGFloat

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    private func digitCount(for width: CGFloat) -> Int {
        let slot = size * 0.52
        let groupGap = size * 0.28
        var count = 1
        while true {
            let candidate = count + 1
            let gaps = CGFloat((candidate - 1) / 3)
            if CGFloat(candidate) * slot + gaps * groupGap > width { return count }
            count = candidate
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let count = digitCount(for: geometry.size.width)
            let numericText = String(Int64(max(0, value)))
            let activeDigits = max(1, numericText.count)
            let firstActiveIndex = max(0, count - activeDigits)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 && (count - index).isMultiple(of: 3) {
                        Spacer().frame(width: size * 0.28)
                    }
                    OdometerDigit(
                        value: value,
                        place: pow(10.0, Double(count - 1 - index)),
                        size: size,
                        active: index >= firstActiveIndex
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: size * 1.18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int64(value)) tokens")
    }
}

struct CounterRow: View {
    let label: String
    let value: Double
    let primary: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).font(.custom("Avenir Next Condensed", size: 9).weight(.semibold))
                .tracking(2.2)
                .foregroundStyle(primary ? Color.cyan.opacity(0.85) : Color.white.opacity(0.42))
                .shadow(color: Color.black.opacity(0.78), radius: 1.4, y: 0.7)
            RollingNumber(value: value, size: primary ? 21 : 16)
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ObserverView: View {
    @ObservedObject var model: TokenModel
    @State private var glow = false
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 7) {
                Spacer()
                Circle().fill(model.isConnected ? Color.cyan : Color.orange).frame(width: 6, height: 6)
                    .shadow(color: Color.cyan.opacity(glow ? 0.9 : 0.25), radius: glow ? 8 : 2)
                Text("CODEX · TOKEN OBSERVER").font(.custom("Avenir Next Condensed", size: 8).weight(.semibold))
                    .tracking(1.4).foregroundStyle(Color.white.opacity(0.42))
                    .shadow(color: Color.black.opacity(0.78), radius: 1.4, y: 0.7)
            }
            CounterRow(label: "TODAY", value: model.today, primary: true)
            Divider().overlay(Color.white.opacity(0.08))
            CounterRow(label: "TOTAL", value: model.total, primary: false)
        }
        .padding(.horizontal, 9).padding(.vertical, 9)
        .frame(width: 335, height: 124)
        .background {
            if model.showPanelBackground {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.025, green: 0.045, blue: 0.075).opacity(0.82))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                }.shadow(color: Color.black.opacity(0.26), radius: 16, y: 7)
            } else {
                Color.clear
            }
        }
        .padding(18)
        .onAppear {
            model.start()
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

enum Corner: String { case left, right }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = TokenModel()
    private var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 371, height: 160),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ObserverView(model: model))
        panel.orderFrontRegardless()
        move(to: Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "right") ?? .right)
        let menu = NSMenu()
        menu.addItem(withTitle: "移到左下角", action: #selector(moveLeft), keyEquivalent: "")
        menu.addItem(withTitle: "移到右下角", action: #selector(moveRight), keyEquivalent: "")
        let backgroundItem = menu.addItem(withTitle: "显示半透明底板", action: #selector(toggleBackground), keyEquivalent: "")
        backgroundItem.state = model.showPanelBackground ? .on : .off
        let demoItem = menu.addItem(withTitle: "叠加视觉测试基数", action: #selector(toggleDemoTotal), keyEquivalent: "")
        demoItem.state = model.demoTotalEnabled ? .on : .off
        menu.addItem(withTitle: "重播双计数动画", action: #selector(replayDualDemo), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Token Observer", action: #selector(quit), keyEquivalent: "q")
        panel.contentView?.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    @objc private func moveLeft() { move(to: .left) }
    @objc private func moveRight() { move(to: .right) }
    @objc private func toggleBackground(_ sender: NSMenuItem) {
        model.showPanelBackground.toggle()
        UserDefaults.standard.set(model.showPanelBackground, forKey: "showPanelBackground")
        sender.state = model.showPanelBackground ? .on : .off
    }
    @objc private func toggleDemoTotal(_ sender: NSMenuItem) {
        model.toggleDemoTotal()
        sender.state = model.demoTotalEnabled ? .on : .off
    }
    @objc private func replayDualDemo() { model.replayDualCounterDemo() }
    @objc private func quit() { NSApp.terminate(nil) }

    func windowDidMove(_ notification: Notification) {
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
