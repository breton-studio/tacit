import Foundation

/// Which way one flip of the frozen MRU ring moves. See `AppSwitchRing` for the ring itself.
public enum AppSwitchDirection: String, Codable, Sendable, CaseIterable {
    case next
    case previous
}

/// Pure state for the "swipe right/left flips apps" feature (2026-08-24 product ruling): a **flip
/// session** freezes the app switcher's own MRU-first order on the FIRST flip of the session, then
/// walks an index into that frozen snapshot — exactly what holding ⌘ and tapping Tab repeatedly
/// does, just without ever posting ⌘Tab or showing the system switcher. No wrap (ruling: a burst
/// of same-direction flips must never circle back around unexpectedly) — `.next` clamps at the end
/// of the frozen list, `.previous` clamps at the front.
///
/// A session ends — and the NEXT flip re-snapshots via the caller-supplied `snapshot()` closure —
/// once `sessionTimeout` seconds pass with no flip (matches `ArbitrationTuning.commandWindow`,
/// 4.0s), or when the caller explicitly calls `invalidate()` (an app activation THIS ring didn't
/// cause — see `AppSwitcher.flip(_:)` in the app target). `snapshot()` is a closure, not a stored
/// value, precisely so a stale list is never used: it's called fresh every time a new session
/// starts, never memoized across flips within a session.
public struct AppSwitchRing: Sendable, Equatable {
    /// The frozen snapshot for the CURRENT session — opaque app identifiers (bundle id or pid
    /// string), MRU-first. Empty before the first flip, or if the most recent (re-)snapshot itself
    /// came back empty.
    public private(set) var items: [String] = []
    /// The currently-selected index into `items`. Meaningless while `items` is empty.
    public private(set) var index: Int = 0
    /// The `now` timestamp of the last flip. Starts at `-.infinity` so the very first flip always
    /// looks "expired" and triggers a snapshot, with no separate optional/"no session yet" flag
    /// needed — `invalidate()` resets this back to the same sentinel for the same reason.
    public private(set) var lastFlipAt: TimeInterval = -.infinity
    public let sessionTimeout: TimeInterval

    public init(sessionTimeout: TimeInterval = 4.0) {
        self.sessionTimeout = sessionTimeout
    }

    /// Advances the ring one step in `direction`, re-snapshotting first if there's no live session
    /// — no prior flip ever happened, the last flip was more than `sessionTimeout` seconds before
    /// `now`, or `invalidate()` was called since. Returns the newly-selected item's identifier, or
    /// `nil` if the (re-)snapshot came back empty.
    @discardableResult
    public mutating func flip(
        _ direction: AppSwitchDirection, snapshot: () -> [String], now: TimeInterval
    ) -> String? {
        if now - lastFlipAt > sessionTimeout {
            items = snapshot()
            index = 0
        }
        lastFlipAt = now

        guard !items.isEmpty else { return nil }

        switch direction {
        case .next: index = min(index + 1, items.count - 1)
        case .previous: index = max(index - 1, 0)
        }
        return items[index]
    }

    /// Ends the current session immediately (an app was activated some other way, e.g. the user
    /// clicked the Dock) — the next flip re-snapshots rather than continuing to walk a now-stale
    /// frozen list.
    public mutating func invalidate() {
        lastFlipAt = -.infinity
    }
}
