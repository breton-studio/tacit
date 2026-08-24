import AppKit
import TacitCore

/// The app-target owner of the "swipe right/left flips apps" feature (2026-08-24 product ruling):
/// wraps the pure `AppSwitchRing` with a live MRU list of running apps, sourced from
/// `NSWorkspace.shared.notificationCenter`, and performs the actual activation via
/// `NSRunningApplication.activate` — directly, never by posting ⌘Tab or showing the system
/// switcher.
///
/// `mruPIDs` is maintained incrementally rather than re-read from `NSWorkspace.shared
/// .runningApplications` on every flip: `didActivateApplicationNotification` moves the activated
/// app's pid to the front (this is what makes the list genuinely "MRU", matching ⌘Tab's strip
/// order), and `didTerminateApplicationNotification` drops a pid that's gone — a poll-based
/// re-read would have no memory of *order*, only of current membership.
///
/// Singleton (`shared`): `LiveActionEnvironment.make()`'s `switchApp` closure is a plain
/// `@Sendable` closure with no reference to the owning `TacitEngine`, so it reaches this instance
/// via the shared static rather than a captured reference — see that file's doc comment for the
/// main-actor hop this requires from `ActionDispatcher.dispatch`'s detached task.
@MainActor
final class AppSwitcher {
    static let shared = AppSwitcher()

    /// `sessionTimeout` uses `AppSwitchRing`'s own default (4.0s), matching
    /// `ArbitrationTuning.commandWindow`'s default — see that type's doc comment.
    private var ring = AppSwitchRing()
    /// Most-recently-used first. Seeded in `init` from `NSWorkspace.shared.runningApplications`
    /// (frontmost first, then the rest in their current order), then maintained incrementally by
    /// the notification observers registered below.
    private var mruPIDs: [pid_t] = []
    /// Set the instant this instance itself calls `activate()`, so the `didActivateApplication`
    /// notification IT causes doesn't get mistaken for an externally-caused activation and
    /// `invalidate()` the in-flight flip session. Cleared once that expected notification arrives
    /// (or immediately overwritten by the next flip).
    private var expectedActivationPID: pid_t?

    /// `nonisolated(unsafe)` purely so `deinit` — which, like every Swift `deinit`, runs
    /// nonisolated even on a `@MainActor` class — can read it to remove the observers; matches
    /// `TacitEngine.systemStateObserverTokens`'s own rationale. Every other access is from `init`
    /// on the main actor, and by the time `deinit` runs nothing else can be touching this instance.
    private nonisolated(unsafe) var observerTokens: [NSObjectProtocol] = []

    private init() {
        let running = NSWorkspace.shared.runningApplications
        let frontmost = NSWorkspace.shared.frontmostApplication
        let eligible = running.filter(Self.isEligible)
        var seeded = eligible.map(\.processIdentifier)
        if let frontmostPID = frontmost?.processIdentifier, let idx = seeded.firstIndex(of: frontmostPID) {
            seeded.remove(at: idx)
            seeded.insert(frontmostPID, at: 0)
        }
        mruPIDs = seeded

        // Both handlers extract only Sendable primitives (`pid_t`/`Bool`) from the notification
        // BEFORE hopping onto the main actor via `MainActor.assumeIsolated` — `Notification` and
        // `NSRunningApplication` aren't `Sendable`, so passing either across that hop directly
        // would be a data-race risk the compiler correctly flags; the extraction itself is just a
        // synchronous property read and needs no isolation of its own. `queue: .main` guarantees
        // this closure runs on the main dispatch queue, which is what backs the main actor's
        // executor — `assumeIsolated` documents that guarantee rather than re-deriving it.
        let center = NSWorkspace.shared.notificationCenter
        let activateToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            let eligible = Self.isEligible(app)
            MainActor.assumeIsolated {
                self?.handleDidActivate(pid: pid, eligible: eligible)
            }
        }
        let terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.handleDidTerminate(pid: pid)
            }
        }
        observerTokens = [activateToken, terminateToken]
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            center.removeObserver(token)
        }
    }

    /// Regular-activation-policy apps only, excluding Tacit itself — matches the ruling's "frozen
    /// list = regular-activation-policy running apps (exclude Tacit itself, exclude
    /// `.prohibited`/`.accessory`)". `nonisolated`: touches no actor-isolated state, and needs to
    /// be callable from the notification closures' synchronous, nonisolated extraction step
    /// (before the `MainActor.assumeIsolated` hop) without incurring an implicit-async warning.
    private nonisolated static func isEligible(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != getpid()
    }

    private func handleDidActivate(pid: pid_t, eligible: Bool) {
        if let expected = expectedActivationPID, expected == pid {
            // An activation THIS instance caused — the flip session stays alive.
            expectedActivationPID = nil
        } else {
            // Some other activation (Dock click, ⌘Tab, app launch, ...) — the frozen list is
            // stale; the next flip must re-snapshot.
            ring.invalidate()
        }

        if eligible {
            mruPIDs.removeAll { $0 == pid }
            mruPIDs.insert(pid, at: 0)
        }
    }

    private func handleDidTerminate(pid: pid_t) {
        mruPIDs.removeAll { $0 == pid }
    }

    /// Flips one step in `direction` and activates the resulting app directly. Returns `false` if
    /// there was nothing to activate (no running apps, or the target pid no longer resolves to a
    /// live `NSRunningApplication`).
    func flip(_ direction: AppSwitchDirection) -> Bool {
        let snapshot = mruPIDs.map(String.init)
        guard let targetString = ring.flip(direction, snapshot: { snapshot }, now: ProcessInfo.processInfo.systemUptime),
              let targetPID = pid_t(targetString),
              let target = NSRunningApplication(processIdentifier: targetPID)
        else {
            TacitLog.actions.info("AppSwitcher.flip(\(direction.rawValue, privacy: .public)) -> no target")
            return false
        }

        let fromName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        expectedActivationPID = targetPID
        guard target.activate() else {
            expectedActivationPID = nil
            TacitLog.actions.info(
                "AppSwitcher.flip(\(direction.rawValue, privacy: .public)) from=\(fromName, privacy: .public) target=\(target.localizedName ?? "?", privacy: .public) activate() failed"
            )
            return false
        }

        TacitLog.actions.notice(
            "AppSwitcher.flip(\(direction.rawValue, privacy: .public)) from=\(fromName, privacy: .public) to=\(target.localizedName ?? "?", privacy: .public)"
        )
        return true
    }
}
