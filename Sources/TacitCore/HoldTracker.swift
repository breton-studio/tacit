import Foundation

/// A hold's lifecycle phase: `.began` when a holdable gesture fires and its pose keeps
/// classifying on the same frame; `.ended` when the pose stops classifying for
/// `HoldTracker.releaseAfterMissingFrames` consecutive frames, or via `HoldTracker.reset()`.
public enum HoldPhase: Equatable, Sendable {
    case began, ended
}

/// One hold-lifecycle transition for a single gesture, emitted by `HoldTracker.ingest`/`reset`.
public struct GestureHoldEvent: Equatable, Sendable {
    public var gesture: GestureID
    public var phase: HoldPhase
    public var timestamp: TimeInterval

    public init(gesture: GestureID, phase: HoldPhase, timestamp: TimeInterval) {
        self.gesture = gesture
        self.phase = phase
        self.timestamp = timestamp
    }
}

/// Tracks whether a holdable static-pose gesture is currently being HELD — the foundation for
/// "point to speak" dictation (hold index-point → key-down Fn, release → key-up).
///
/// `HoldTracker` is driven entirely by the `now`/`at:` parameters its callers pass in (mirroring
/// `ArbitrationEngine`'s zero-`Date()` discipline) — it makes no wall-clock reads of its own, so
/// fixture replay stays fully deterministic.
///
/// Only ONE hold can be active at a time: while a hold is in progress, `ingest`'s `fired`
/// parameter is ignored entirely — a re-fire of the SAME gesture (e.g. once its cooldown clears)
/// or a fire of a DIFFERENT holdable gesture mid-hold neither restarts nor redirects the current
/// hold. A hold's lifecycle, once begun, is driven solely by whether its own pose keeps
/// classifying — never by another `fired` event arriving in the meantime.
///
/// The failure mode this type exists to make impossible is a stuck-down key: every `began` this
/// type ever emits is guaranteed to be followed, eventually, by a matching `ended` — either
/// organically (the pose stops classifying) or forced via `reset()` — so a caller that always
/// posts a key-up on `ended` (and calls `reset()` on every other reason a hold must stop, e.g. a
/// disarm, a capture pause, a screen lock, or the app quitting) can never leave a key held down
/// with nothing left to release it.
public struct HoldTracker: Sendable {
    private let holdableGestures: Set<GestureID>
    private let releaseAfterMissingFrames: Int

    /// The gesture currently being held, or `nil` if nothing is.
    private var activeGesture: GestureID?
    /// Consecutive frames (while `activeGesture != nil`) whose `candidate` did NOT match
    /// `activeGesture` — reset to 0 the instant a matching candidate arrives. Reaching
    /// `releaseAfterMissingFrames` ends the hold; anything below that is forgiven, so a single
    /// frame of classifier jitter can never end a hold on its own (which would fire a spurious
    /// key-up/key-down pair mid-dictation).
    private var missingFrames = 0
    /// The most recent `now` seen by `ingest` — used as `reset()`'s `ended` event timestamp,
    /// since `reset()`'s signature (fixed by the brief) takes no `at:` parameter of its own: a
    /// caller resetting from outside the per-frame loop (a capture-state change, a screen lock, an
    /// app-quit notification) has no frame timestamp of its own to hand in either.
    private var lastKnownTimestamp: TimeInterval = 0

    public init(holdableGestures: Set<GestureID>, releaseAfterMissingFrames: Int = 2) {
        self.holdableGestures = holdableGestures
        self.releaseAfterMissingFrames = releaseAfterMissingFrames
    }

    /// Feed exactly one sample per inference frame: the fired event (if any fired this frame) and
    /// the raw static candidate (if any pose is currently classifying) — both `nil` on a frame
    /// with no hand. Returns a `GestureHoldEvent` on a phase transition, `nil` on a frame that
    /// changes nothing.
    ///
    /// - **Not currently holding:** begins a hold only when `fired` names a gesture in
    ///   `holdableGestures` AND `candidate` is non-`nil` and names that SAME gesture on this SAME
    ///   frame — i.e. the pose that just fired is still being held, not a one-frame flash that's
    ///   already gone by the time this is called. A fire of a non-holdable gesture, a fire with no
    ///   candidate, or a fire whose candidate names a different gesture never begins a hold.
    /// - **Currently holding:** `fired` is ignored entirely (see the type's doc comment); only
    ///   `candidate` matters. A candidate matching `activeGesture` resets `missingFrames` to 0 (no
    ///   event). A non-matching candidate (including `nil`) increments `missingFrames`; reaching
    ///   `releaseAfterMissingFrames` ends the hold and returns `.ended`, anything below that
    ///   returns `nil` (forgiven).
    public mutating func ingest(
        fired: GestureEvent?, candidate: GestureCandidate?, at now: TimeInterval
    ) -> GestureHoldEvent? {
        lastKnownTimestamp = now

        guard let activeGesture else {
            guard let fired, holdableGestures.contains(fired.gesture),
                  candidate?.gesture == fired.gesture
            else { return nil }
            self.activeGesture = fired.gesture
            missingFrames = 0
            return GestureHoldEvent(gesture: fired.gesture, phase: .began, timestamp: now)
        }

        if candidate?.gesture == activeGesture {
            missingFrames = 0
            return nil
        }

        missingFrames += 1
        guard missingFrames >= releaseAfterMissingFrames else { return nil }

        self.activeGesture = nil
        missingFrames = 0
        return GestureHoldEvent(gesture: activeGesture, phase: .ended, timestamp: now)
    }

    /// Unconditionally ends any active hold, as if its pose had just vanished for good — the
    /// chokepoint every non-pose-based ended-path (disarm/window-expiry, capture pause/
    /// unavailable, screen lock, `isEnabled` off, app quit, …) routes through. Returns the
    /// `.ended` event if a hold was active, `nil` if nothing was being held (idempotent — safe to
    /// call from multiple overlapping shutdown paths without double-firing an event).
    public mutating func reset() -> GestureHoldEvent? {
        guard let activeGesture else { return nil }
        self.activeGesture = nil
        missingFrames = 0
        return GestureHoldEvent(gesture: activeGesture, phase: .ended, timestamp: lastKnownTimestamp)
    }
}
