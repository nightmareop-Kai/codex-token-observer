#if DEBUG
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Renders the production view with fixtures, without starting the collector
/// or accessing the user's database. Only included in debug builds.
@MainActor
enum ObserverPreview {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-output"),
              arguments.indices.contains(index + 1) else { return false }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let projects = [
                ProjectSnapshot(name: "设计与硬件", path: "/preview/design", total: 3_696_564_114, today: 8_304_762),
                ProjectSnapshot(name: "一个特别长的中文项目名称用于检查换行", path: "/preview/long-name", total: 1_996_430_161, today: 0),
                ProjectSnapshot(name: "Project Atlas", path: "/preview/atlas", total: 240_499_405, today: 98_765)
            ]
            for background in [false, true] {
                try render(
                    name: background ? "panel" : "transparent", directory: directory,
                    projects: projects, background: background
                )
            }
            try render(name: "empty", directory: directory, projects: [], background: true)
            try render(name: "loading", directory: directory, projects: [], background: true, connected: false)
            try render(name: "unassigned", directory: directory, projects: [
                ProjectSnapshot(name: "UNKNOWN", path: "", total: 1_234, today: 123)
            ], background: true)
            try render(name: "yellow", directory: directory, projects: projects, background: true, quotaPercent: 75)
            try render(name: "stale", directory: directory, projects: projects, background: true, quotaPercent: 75, stale: true)
            try render(name: "over-limit", directory: directory, projects: projects, background: true, quotaPercent: 127)
            try render(name: "quota-unavailable", directory: directory, projects: projects, background: true, quotaPercent: nil)
            try render(name: "quota-full", directory: directory, projects: projects, background: true, quotaPercent: 0)
            try render(name: "quota-exhausted", directory: directory, projects: projects, background: true, quotaPercent: 100)
            try render(name: "quota-after-reset", directory: directory, projects: projects, background: true,
                       quotaPercent: 7, cumulativePercent: 197)
            let extraProjects = (4...12).map { index in
                ProjectSnapshot(name: "示例项目 \(index)", path: "/preview/project-\(index)", total: Double(10_000_000 / index), today: Double(12_000 / index))
            }
            try render(name: "expanded", directory: directory, projects: projects + extraProjects, background: true, expanded: true)
            try render(name: "large-number", directory: directory, projects: [
                ProjectSnapshot(name: "大数值容量检查", path: "/preview/large", total: 123_456_789_012_345, today: 1_234_567_890_123)
            ], background: true)
            try render(name: "carry", directory: directory, projects: [
                ProjectSnapshot(name: "进位动画检查", path: "/preview/carry", total: 999_999.5, today: 99.5)
            ], background: true)
            // Exercise the native material against both system appearances,
            // while retaining the Classic fixtures above for comparison.
            for scheme in [ColorScheme.light, .dark] {
                let prefix = scheme == .light ? "mist-light" : "mist-dark"
                try render(name: prefix, directory: directory, projects: projects,
                           background: true, appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-quota-full", directory: directory, projects: projects,
                           background: true, quotaPercent: 0, appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-quota-exhausted", directory: directory, projects: projects,
                           background: true, quotaPercent: 100, appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-quota-after-reset", directory: directory, projects: projects,
                           background: true, quotaPercent: 7, cumulativePercent: 197,
                           appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-quota-stale", directory: directory, projects: projects,
                           background: true, quotaPercent: 7, stale: true,
                           appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-quota-unavailable", directory: directory, projects: projects,
                           background: true, quotaPercent: nil, appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-expanded", directory: directory,
                           projects: projects + extraProjects, background: true, expanded: true,
                           appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-over-limit", directory: directory, projects: projects,
                           background: true, quotaPercent: 127,
                           appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-large-number", directory: directory, projects: [
                    ProjectSnapshot(name: "大数值容量检查", path: "/preview/large",
                                    total: 123_456_789_012_345, today: 1_234_567_890_123)
                ], background: true, appearance: .mist, colorScheme: scheme,
                           today: 1_234_567_890_123, total: 123_456_789_012_345)
                try render(name: "\(prefix)-transparent", directory: directory, projects: projects,
                           background: false, appearance: .mist, colorScheme: scheme)
                try render(name: "\(prefix)-leaderboard", directory: directory, projects: projects,
                           background: true, appearance: .mist, colorScheme: scheme, page: .leaderboard)
                try render(name: "\(prefix)-leaderboard-expanded", directory: directory,
                           projects: projects + extraProjects, background: true, expanded: true,
                           appearance: .mist, colorScheme: scheme, page: .leaderboard)
                try render(name: "\(prefix)-leaderboard-transparent", directory: directory, projects: projects,
                           background: false, appearance: .mist, colorScheme: scheme, page: .leaderboard)
                for status in ["loading", "ok", "offline", "not_configured"] {
                    try render(name: "\(prefix)-leaderboard-\(status)", directory: directory, projects: projects,
                               background: true, appearance: .mist, colorScheme: scheme, page: .leaderboard,
                               board: LeaderboardSnapshot(status: status))
                }
                try render(name: "\(prefix)-leaderboard-stale", directory: directory, projects: projects,
                           background: true, appearance: .mist, colorScheme: scheme, page: .leaderboard,
                           board: LeaderboardSnapshot.sample().asOffline())
                let sample = LeaderboardSnapshot.sample()
                try render(name: "\(prefix)-leaderboard-upload-pending", directory: directory, projects: projects,
                           background: true, appearance: .mist, colorScheme: scheme, page: .leaderboard,
                           board: LeaderboardSnapshot(status: "ok", date: sample.date, entries: sample.entries,
                                                      totalParticipants: sample.totalParticipants, ownEntry: sample.ownEntry,
                                                      error: "sync_failed", ownEntryStale: true, isSample: true))
                try render(name: "\(prefix)-leaderboard-sharing-paused", directory: directory, projects: projects,
                           background: true, appearance: .mist, colorScheme: scheme, page: .leaderboard,
                           profileState: "paused")
                for status in ["needs_name", "active", "paused", "pending", "upload-pending"] {
                    let profile = ZunoProfile(status: status == "upload-pending" ? "active" : status,
                                              id: status == "needs_name" ? nil : "00000000-0000-4000-8000-000000000086",
                                              nickname: status == "needs_name" ? nil : "小庄",
                                              error: status == "pending" ? "offline" : status == "upload-pending" ? "sync_failed" : nil)
                    let view = ProfileContent(profile: profile, busy: false, requestError: nil,
                                              onRegister: { _ in }, onToggleSync: {}, onClose: {})
                        .environment(\.colorScheme, scheme)
                    try capture(view, name: "\(prefix)-profile-\(status)", directory: directory, colorScheme: scheme)
                }
            }
            try render(name: "classic-leaderboard", directory: directory, projects: projects,
                       background: true, page: .leaderboard)
            try render(name: "classic-leaderboard-expanded", directory: directory, projects: projects,
                       background: true, expanded: true, page: .leaderboard)
            try render(name: "classic-leaderboard-transparent", directory: directory, projects: projects,
                       background: false, page: .leaderboard)
        } catch {
            print("Preview failed: \(error)")
        }
        return true
    }

    private static func render(name: String, directory: URL, projects: [ProjectSnapshot], background: Bool,
                               quotaPercent: Double? = 46, cumulativePercent: Double? = nil, expanded: Bool = false,
                               connected: Bool = true, stale: Bool = false,
                               appearance: ObserverAppearance = .classic, colorScheme: ColorScheme = .dark,
                               today: Double? = nil, total: Double? = nil,
                               page: ObserverPage = .counter, board: LeaderboardSnapshot? = nil,
                               profileState: String = "active") throws {
        let quota = quotaPercent.map { percent in
            QuotaSnapshot(available: true, currentPercent: percent,
                          cumulativePercent: cumulativePercent ?? percent, resetsAt: Date().timeIntervalSince1970 + 86400,
                          observedAt: nil, resetCount: cumulativePercent != nil ? 1 : 0,
                          stale: stale, estimated: cumulativePercent != nil)
        }
        let content = ObserverContent(
            today: today ?? (projects.isEmpty ? 0 : 8_403_527),
            total: total ?? (projects.isEmpty ? 0 : 6_172_098_410),
            projects: projects.sorted { $0.today == $1.today ? $0.total > $1.total : $0.today > $1.today },
            isConnected: connected, showPanelBackground: background,
            quota: quota, showAllProjects: expanded, appearance: appearance, page: page,
            leaderboardSnapshot: board ?? .sample(),
            profile: ZunoProfile(status: profileState, id: "demo-you", nickname: "小庄", error: nil)
        )
        .environment(\.colorScheme, colorScheme)
        .background(colorScheme == .light
                    ? Color(red: 0.88, green: 0.90, blue: 0.93)
                    : Color(red: 0.065, green: 0.085, blue: 0.11))
        try capture(content, name: name, directory: directory, colorScheme: colorScheme)
    }

    private static func capture<V: View>(_ content: V, name: String, directory: URL, colorScheme: ColorScheme) throws {
        // ImageRenderer omits AppKit-backed ScrollView content on macOS. Mount
        // the real view in an offscreen panel and cache its display instead.
        let host = NSHostingView(rootView: content)
        let nativeAppearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
        host.appearance = nativeAppearance
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = nativeAppearance
        panel.contentView = host
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        defer { panel.close() }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(ceil(size.width * 3)), pixelsHigh: Int(ceil(size.height * 3)),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        print("\(name): \(image.width / 3) × \(image.height / 3) pt — \(url.path)")
    }
}
#endif
