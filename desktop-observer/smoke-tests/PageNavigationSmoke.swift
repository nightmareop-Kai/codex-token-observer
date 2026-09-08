import AppKit

/// Compile with LeaderboardSnapshot.swift and PanelNavigation.swift.
/// No TokenModel, user preferences, database, or network is opened.
@main
struct PageNavigationSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let state = PanelNavigation()
        precondition(state.page == .counter)
        precondition(state.page.switchTitle == "Leaderboard")
        state.toggle()
        precondition(state.page == .leaderboard)
        precondition(state.page.switchTitle == "Back to Counter")
        state.toggle()
        precondition(state.page == .counter)
        for _ in 0..<20 { state.toggle() }
        precondition(state.page == .counter)

        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 297),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 297))
        panel.contentView = host
        let exclusion = PageExclusionView(frame: NSRect(x: 220, y: 250, width: 50, height: 24))
        host.addSubview(exclusion)
        let gesture = PanelPageGesture(host: host) { state.toggle() }
        precondition(host.gestureRecognizers.count == 1)
        let click = host.gestureRecognizers[0] as! PageDoubleClickRecognizer
        precondition(click.numberOfClicksRequired == 2)
        precondition(click.buttonMask == 1)
        precondition(!click.delaysPrimaryMouseButtonEvents, "Window dragging must not wait for double-click recognition")
        precondition(gesture.isExcluded(NSPoint(x: 230, y: 260)))
        precondition(!gesture.isExcluded(NSPoint(x: 80, y: 260)))
        precondition(exclusion.hitTest(NSPoint(x: 10, y: 10)) == nil)
        exclusion.excludesPageClick = false
        precondition(!gesture.isExcluded(NSPoint(x: 230, y: 260)))
        exclusion.excludesPageClick = true
        exclusion.isHidden = true
        precondition(!gesture.isExcluded(NSPoint(x: 230, y: 260)))
        exclusion.isHidden = false

        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: 260),
                                      modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        precondition(gesture.gestureRecognizer(click, shouldAttemptToRecognizeWith: event))
        let originalFrame = panel.frame
        state.toggle()
        precondition(panel.frame == originalFrame)
        state.toggle()
        precondition(panel.frame == originalFrame)
        panel.setFrameOrigin(NSPoint(x: originalFrame.minX + 20, y: originalFrame.minY))
        precondition(!gesture.gestureRecognizerShouldBegin(click), "A dragged window must not switch pages")
        gesture.stop()
        precondition(host.gestureRecognizers.isEmpty)
        panel.close()
        print("Page navigation smoke passed: defaults, no runtime sample, round trips, transparent hit regions, native non-delayed double-click, fixed frame, drag rejection, and teardown.")
    }
}
