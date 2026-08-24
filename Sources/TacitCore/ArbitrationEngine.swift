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
    /// Minimum time between two fires of the *same* gesture, for gestures in
    /// `ArbitrationEngine.repeatableGestures` (rotate/scroll ticks) — shorter than `cooldown` so a
    /// sustained motion can emit a tick per increment instead of being rate-limited like a discrete
    /// momentary gesture.
    public var repeatCooldown: TimeInterval = 0.2
    /// How long after the clutch completes a disarmed/arming → armed transition a `.fistToOpen`
    /// candidate is suppressed by `ArbitrationEngine.ingestPreDebounced` — no event, no cooldown
    /// ledger entry written, as if the candidate never arrived. The fist held to arm the clutch
    /// opening into whatever the user does next (a tap, a swipe, releasing the hand entirely) is
    /// not itself a deliberate `.fistToOpen` gesture; without this, EVERY clutch arm-then-release
    /// would masquerade as one. A genuine `.fistToOpen` performed later in the SAME armed
    /// session — well past this window — fires completely normally: this only gates the instant
    /// right after arming, never a deliberate mid-session fist-to-open.
    public var postArmSuppression: TimeInterval = 0.6
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

    /// The `now` at which the clutch most recently completed a disarmed/arming → armed
    /// transition (nil before the first arming, or after `reset()`). Set exactly once per arming,
    /// inside `processClutch` — NOT touched by `ingestPreDebounced`'s window-extension-on-fire,
    /// which re-assigns `state` but is not a fresh arming. Read only by `ingestPreDebounced`'s
    /// post-arm `.fistToOpen` suppression; see `ArbitrationTuning.postArmSuppression`'s doc comment.
    private var lastArmedAt: TimeInterval?

    /// Gestures that emit a *repeated* tick per motion increment while engaged (wrist-rotate,
    /// two-finger-scroll) rather than a single discrete fire. These use `tuning.repeatCooldown`
    /// instead of `tuning.cooldown` in `ingestPreDebounced`'s per-gesture cooldown check.
    public static let repeatableGestures: Set<GestureID> = [
        .wristRotateCW, .wristRotateCCW, .twoFingerScrollUp, .twoFingerScrollDown
    ]

    /// Slack subtracted from a cooldown duration before the `now - last < cooldown` comparison, so
    /// that a gap which is *supposed* to equal the cooldown exactly (e.g. two ticks arriving
    /// `repeatCooldown` seconds apart) reliably clears it instead of being at the mercy of
    /// `TimeInterval` (`Double`) representation noise — e.g. `1.0 + 2 * 0.1` is
    /// `0.19999999999999996` short of `0.2`, which without this slack would still count as inside
    /// a 0.2s cooldown and silently swallow a tick that should have fired.
    private static let cooldownEpsilon: TimeInterval = 1e-9

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
        lastArmedAt = nil
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

    /// Task 21 controller ruling (R1): a SEPARATE entry point for momentary candidates — taps and
    /// swipes — whose detectors already self-debounce in time (a tap only ever emits on its
    /// release frame; a swipe only on the single frame its travel threshold is crossed). Feeding
    /// either into `ingest`'s normal path could never accumulate `debounceFrames` consecutive
    /// frames of the same gesture, so it could never fire there. This method is the fix: no
    /// arming, no disarming, no debounce accumulation at all — just the armed-window check, a
    /// confidence floor, the reserved-gesture guard, and the same per-gesture cooldown ledger
    /// `ingest` uses (shared, so a gesture fired through either path respects the other path's
    /// most recent fire).
    ///
    /// Fires iff: `state` is `.armed` AND `now` is still inside that window AND
    /// `candidate.confidence >= enterConfidence` AND `candidate.gesture` isn't reserved
    /// (`.looseFist`/`.openPalm` are never fireable through either path) AND the per-gesture
    /// cooldown is clear — `tuning.repeatCooldown` for gestures in `repeatableGestures`
    /// (rotate/scroll ticks, so a sustained motion can fire on every increment), `tuning.cooldown`
    /// for everything else, both compared with `cooldownEpsilon` slack so a gap that's meant to
    /// exactly clear the cooldown does so regardless of `Double` representation noise. On fire,
    /// extends `windowEndsAt` to `now + commandWindow` — identical
    /// to a normal `ingest` fire — and records the cooldown. Never touches `armingStartAt`,
    /// `debounceGesture`, or `debounceCount`, so it can neither arm/disarm the clutch nor perturb
    /// an in-flight static-pose debounce running through `ingest`.
    ///
    /// **Post-arm `.fistToOpen` suppression** (controller fix, M3 Task 5 follow-up): a
    /// `.fistToOpen` candidate arriving within `tuning.postArmSuppression` of the most recent
    /// disarmed/arming → armed transition (`lastArmedAt`) is dropped here — no event, no cooldown
    /// ledger entry — because it's the arming fist's own opening into whatever the user does
    /// next, not a deliberate gesture. This is checked and returned BEFORE the cooldown lookup
    /// below, so it never consumes `.fistToOpen`'s cooldown slot; a genuine `.fistToOpen`
    /// performed later in the same armed session (once this window has passed) fires exactly as
    /// if the suppressed candidate had never arrived. Every other gesture is unaffected.
    public func ingestPreDebounced(_ candidate: GestureCandidate, at now: TimeInterval) -> GestureEvent? {
        guard case .armed(let windowEndsAt) = state, now < windowEndsAt else { return nil }
        guard candidate.confidence >= tuning.enterConfidence else { return nil }
        guard !GestureCatalog.entry(for: candidate.gesture).isReserved else { return nil }

        let gesture = candidate.gesture

        if gesture == .fistToOpen, let lastArmedAt, now - lastArmedAt < tuning.postArmSuppression {
            return nil
        }

        let cooldown = Self.repeatableGestures.contains(gesture) ? tuning.repeatCooldown : tuning.cooldown
        if let last = lastFiredAt[gesture], now - last < cooldown - Self.cooldownEpsilon {
            return nil
        }

        lastFiredAt[gesture] = now
        state = .armed(windowEndsAt: now + tuning.commandWindow)
        return GestureEvent(gesture: gesture, timestamp: now)
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
            lastArmedAt = now
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

        if let last = lastFiredAt[gesture], now - last < tuning.cooldown - Self.cooldownEpsilon {
            return nil
        }

        lastFiredAt[gesture] = now
        state = .armed(windowEndsAt: now + tuning.commandWindow)
        return GestureEvent(gesture: gesture, timestamp: now)
    }
}
