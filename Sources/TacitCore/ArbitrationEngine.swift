import Foundation

/// Tuning knobs for `ArbitrationEngine`. All time values are seconds.
public struct ArbitrationTuning: Sendable {
    /// How long `.looseFist` must be sustained (disarmed) before the clutch arms.
    public var clutchHold: TimeInterval = 0.4
    /// How long a command window stays open (from arming, or from the last fired event) before auto-disarming.
    public var commandWindow: TimeInterval = 4.0
    /// Consecutive qualifying frames required before a debounced candidate fires (or disarms via openPalm).
    public var debounceFrames: Int = 3
    /// Minimum time between two fires of the *same* gesture.
    public var cooldown: TimeInterval = 0.8
    /// Confidence required for a frame to *start* (or restart, after a gesture switch) a debounce count.
    public var enterConfidence: Double = 0.6
    /// Confidence required for a frame to *continue* an already-started debounce count (hysteresis).
    public var stayConfidence: Double = 0.45

    public init() {}
}

/// The arbitration engine's current phase.
public enum ArbitrationState: Equatable, Sendable {
    /// No clutch pose held; nothing but `.looseFist` can do anything.
    case disarmed
    /// `.looseFist` is being held; `progress` is 0...1 of `clutchHold`.
    case arming(progress: Double)
    /// The clutch is armed; non-reserved gestures may fire until `windowEndsAt`.
    case armed(windowEndsAt: TimeInterval)
}

/// The trust core of Tacit: a clutch-gated state machine that turns raw per-frame pose
/// candidates into deliberate gesture events, guarding against accidental ("Midas touch") firing.
///
/// `ArbitrationEngine` is driven entirely by the `now` parameter passed to `ingest` — it holds
/// zero wall-clock state and makes zero calls to `Date()`, so fixture replay is fully deterministic.
public final class ArbitrationEngine {
    private let tuning: ArbitrationTuning

    public private(set) var state: ArbitrationState = .disarmed

    /// Timestamp at which the current unbroken `.looseFist` hold began (disarmed/arming phase only).
    private var armingStartAt: TimeInterval?

    /// The gesture currently accumulating debounce frames while armed (nil when nothing is being tracked).
    private var debounceGesture: GestureID?
    private var debounceCount: Int = 0

    /// Last time each gesture successfully fired an event, for per-gesture cooldown.
    private var lastFiredAt: [GestureID: TimeInterval] = [:]

    public init(tuning: ArbitrationTuning = ArbitrationTuning()) {
        self.tuning = tuning
    }

    /// Returns the engine to `.disarmed` with every counter cleared, as if newly constructed.
    public func reset() {
        state = .disarmed
        armingStartAt = nil
        debounceGesture = nil
        debounceCount = 0
        lastFiredAt = [:]
    }

    /// Feed exactly one sample per inference frame (nil = nothing classified this frame).
    /// Returns a fired event, or nil. Mutates `state`.
    public func ingest(_ candidate: GestureCandidate?, at now: TimeInterval) -> GestureEvent? {
        switch state {
        case .disarmed, .arming:
            processClutch(candidate, now: now)
            return nil

        case .armed(let windowEndsAt):
            if now >= windowEndsAt {
                disarm()
                // The window just expired; evaluate this same frame under disarmed rules
                // (e.g. a `.looseFist` candidate here legitimately starts a fresh arming hold).
                processClutch(candidate, now: now)
                return nil
            }
            return processArmed(candidate, now: now)
        }
    }

    // MARK: - Disarmed / arming phase (the clutch itself)

    private func processClutch(_ candidate: GestureCandidate?, now: TimeInterval) {
        guard let candidate, candidate.gesture == .looseFist else {
            // Anything other than a sustained fist (including nothing at all) breaks the hold.
            disarm()
            return
        }

        let startedAt = armingStartAt ?? now
        armingStartAt = startedAt
        let elapsed = now - startedAt

        if elapsed >= tuning.clutchHold {
            armingStartAt = nil
            debounceGesture = nil
            debounceCount = 0
            state = .armed(windowEndsAt: now + tuning.commandWindow)
        } else {
            let progress = tuning.clutchHold > 0 ? min(max(elapsed / tuning.clutchHold, 0), 1) : 1
            state = .arming(progress: progress)
        }
    }

    private func disarm() {
        state = .disarmed
        armingStartAt = nil
        debounceGesture = nil
        debounceCount = 0
    }

    // MARK: - Armed phase (debounce, hysteresis, cooldown, openPalm disarm)

    private func processArmed(_ candidate: GestureCandidate?, now: TimeInterval) -> GestureEvent? {
        guard let candidate else {
            debounceGesture = nil
            debounceCount = 0
            return nil
        }

        // A fist seen while armed is neither a fire nor a re-arm: it's simply ignored, leaving
        // any in-progress debounce of another gesture untouched.
        if candidate.gesture == .looseFist {
            return nil
        }

        if candidate.gesture == debounceGesture {
            guard candidate.confidence >= tuning.stayConfidence else {
                debounceGesture = nil
                debounceCount = 0
                return nil
            }
            debounceCount += 1
        } else {
            guard candidate.confidence >= tuning.enterConfidence else {
                debounceGesture = nil
                debounceCount = 0
                return nil
            }
            debounceGesture = candidate.gesture
            debounceCount = 1
        }

        guard debounceCount >= tuning.debounceFrames else { return nil }

        // Debounce threshold reached: consume this attempt regardless of outcome, so a further
        // hold of the same gesture must re-debounce from scratch before it can act again.
        let gesture = candidate.gesture
        debounceGesture = nil
        debounceCount = 0

        if gesture == .openPalm {
            disarm()
            return nil
        }

        if let last = lastFiredAt[gesture], now - last < tuning.cooldown {
            return nil
        }

        lastFiredAt[gesture] = now
        state = .armed(windowEndsAt: now + tuning.commandWindow)
        return GestureEvent(gesture: gesture, timestamp: now)
    }
}
