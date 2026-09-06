import AppKit

/// Keeps the observer above Codex/ChatGPT, while allowing other apps to cover it.
/// This observes app activation events; it never polls or changes keyboard focus.
@MainActor
final class ForegroundPolicy {
    private let onChange: @MainActor (Bool) -> Void
    private let ownBundleIdentifier: String?
    private var subscription: WorkspaceActivationSubscription?
    private var generation = 0
    private var lastReportedState: Bool?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        ownBundleIdentifier = Bundle.main.bundleIdentifier
    }

    /// Exact native-app identifiers only. Browser tabs do not affect this policy.
    nonisolated static func shouldFloat(bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier {
        case "com.openai.codex", "com.openai.chat":
            return true
        default:
            return false
        }
    }

    /// Resolve own-app interactions without changing the last external-app state.
    nonisolated static func resolvedState(
        bundleIdentifier: String?,
        ownBundleIdentifier: String?,
        previousState: Bool?
    ) -> Bool {
        if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier {
            return previousState ?? false
        }
        return shouldFloat(bundleIdentifier: bundleIdentifier)
    }

    func start() {
        guard subscription == nil else { return }
        generation += 1
        let currentGeneration = generation
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = application?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.subscription != nil else { return }
                self.handleActivation(bundleIdentifier: bundleIdentifier)
            }
        }
        subscription = WorkspaceActivationSubscription(center: center, token: token)
        handleActivation(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func stop() {
        generation += 1
        subscription = nil
        lastReportedState = nil
    }

    private func handleActivation(bundleIdentifier: String?) {
        // Opening our menu or reopening the observer should not alternate levels.
        // At initial launch there is no prior state, so default to normal stacking.
        report(Self.resolvedState(
            bundleIdentifier: bundleIdentifier,
            ownBundleIdentifier: ownBundleIdentifier,
            previousState: lastReportedState
        ))
    }

    private func report(_ shouldFloat: Bool) {
        guard lastReportedState != shouldFloat else { return }
        lastReportedState = shouldFloat
        onChange(shouldFloat)
    }
}

/// Immutable ownership wrapper: NotificationCenter supports removing its observer
/// from any thread, including when the owner is deallocated outside the main actor.
private final class WorkspaceActivationSubscription: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}
