import AppKit
import SwiftUI

/// Pure native fixture. It never constructs TokenModel, reads a ledger or runs a CLI.
@MainActor
private final class Fixture: ObservableObject {
    @Published var profile = ZunoProfile(status: "needs_name", id: nil, nickname: nil, error: nil)
    @Published var busy = false
    @Published var error: String?
    var registrations = 0
}

private struct FixtureView: View {
    @ObservedObject var state: Fixture
    var body: some View {
        ProfileContent(profile: state.profile, busy: state.busy, requestError: state.error,
                       onRegister: { _ in state.registrations += 1 }, onToggleSync: {}, onClose: {})
    }
}

@main
struct ProfileWindowSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let fixture = Fixture()
        let host = NSHostingView(rootView: FixtureView(state: fixture))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 364, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderBack(nil)
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.width == 364, "Profile width stays compact")
            precondition(window.contentLayoutRect.height >= host.fittingSize.height - 1,
                         "Native window must grow to avoid clipping permanent-name or error copy")
            precondition(fixture.registrations == 0, "Presentation and state transitions never join automatically")
        }
        settle()
        fixture.busy = true
        settle()
        fixture.busy = false
        fixture.error = "Could not reach the leaderboard. Your local counts are safe. Please retry."
        settle()
        fixture.profile = ZunoProfile(status: "pending", id: "synthetic-local-only", nickname: "小庄", error: "offline")
        settle()
        fixture.profile = ZunoProfile(status: "active", id: "00000000-0000-4000-8000-000000000086", nickname: String(repeating: "庄", count: 24), error: nil)
        fixture.error = nil
        settle()
        fixture.profile = ZunoProfile(status: "paused", id: "00000000-0000-4000-8000-000000000086", nickname: "小庄", error: nil)
        settle()
        window.close()
        precondition(fixture.registrations == 0)
        print("Profile window smoke passed: needs-name, busy, failure, pending, permanent-long-name, paused, automatic resizing, and no registration on presentation or close.")
    }
}
