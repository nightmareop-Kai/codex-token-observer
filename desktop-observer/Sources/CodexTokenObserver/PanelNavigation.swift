import AppKit
import SwiftUI

enum ObserverPage: String {
    case counter, leaderboard
    var switchTitle: String { self == .counter ? "Leaderboard" : "Back to Counter" }
}

/// Presentation only: no persistence, collector, account, or network access.
@MainActor
final class PanelNavigation: ObservableObject {
    @Published private(set) var page = ObserverPage.counter

    func toggle() {
        if page == .counter { page = .leaderboard }
        else { page = .counter }
    }

}

private struct PageInteractionsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var pageInteractionsEnabled: Bool {
        get { self[PageInteractionsEnabledKey.self] }
        set { self[PageInteractionsEnabledKey.self] = newValue }
    }
}

/// Marks buttons and scrolling regions without consuming their mouse events.
struct PageInteractionExclusion: NSViewRepresentable {
    @Environment(\.pageInteractionsEnabled) private var enabled
    func makeNSView(context: Context) -> PageExclusionView { PageExclusionView() }
    func updateNSView(_ view: PageExclusionView, context: Context) { view.excludesPageClick = enabled }
}

final class PageExclusionView: NSView {
    var excludesPageClick = true
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Native click recognition waits for mouse-up and cancels on a drag. It does
/// not delay the original mouse events needed for window dragging or buttons.
final class PageDoubleClickRecognizer: NSClickGestureRecognizer {
    private var pressLocation: NSPoint?
    override func mouseDown(with event: NSEvent) {
        pressLocation = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if let start = pressLocation,
           hypot(location.x - start.x, location.y - start.y) > 4 {
            state = .failed
        }
    }
    override func reset() { super.reset(); pressLocation = nil }
}

@MainActor
final class PanelPageGesture: NSObject, NSGestureRecognizerDelegate {
    private weak var host: NSView?
    private var originalWindowOrigin: NSPoint?
    private let onToggle: () -> Void
    private var click: PageDoubleClickRecognizer!

    init(host: NSView, onToggle: @escaping () -> Void) {
        self.host = host
        self.onToggle = onToggle
        super.init()
        click = PageDoubleClickRecognizer(target: self, action: #selector(recognized))
        click.numberOfClicksRequired = 2
        click.buttonMask = 1
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        host.addGestureRecognizer(click)
    }

    func stop() { host?.removeGestureRecognizer(click); click.delegate = nil }

    func isExcluded(_ point: NSPoint) -> Bool {
        guard let host else { return true }
        func containsExclusion(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if let marker = view as? PageExclusionView, marker.excludesPageClick,
               marker.bounds.contains(marker.convert(point, from: nil)) { return true }
            return view.subviews.contains(where: containsExclusion)
        }
        return containsExclusion(host)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        originalWindowOrigin = host?.window?.frame.origin
        return !isExcluded(event.locationInWindow)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let origin = originalWindowOrigin, let current = host?.window?.frame.origin else { return false }
        return hypot(current.x - origin.x, current.y - origin.y) < 1
            && !isExcluded(gestureRecognizer.location(in: nil))
    }

    @objc private func recognized() {
        guard click.state == .ended else { return }
        onToggle()
    }
}
