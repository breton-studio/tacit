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

    /// Product ruling (2026-08-24): whether the clutch (a sustained `.looseFist` hold) must be
    /// armed before gestures can fire. `true` (default) is the original clutch-gated behavior —
    /// `ArbitrationEngine` starts `.disarmed`, and only a completed clutch hold ever lets a
    /// non-reserved gesture debounce/fire. `false` — the app's own persisted default, set after a
    /// user's fist clutch misread (the log showed `arming → disarmed` bouncing ten times before
    /// ever arming) — skips the clutch entirely: the engine reports `.armed(windowEndsAt:
    /// .infinity)` for its whole lifetime, any non-reserved gesture that clears debounce fires
    /// immediately, and the command window never expires. `looseFist`/`openPalm` stay reserved
    /// (unbindable) but simply do nothing when ingested — no event, no state change — rather than
    /// arming/disarming anything. See `ArbitrationEngine`'s `ingest`/`ingestPreDebounced` doc
    /// comments for the exact mechanics.
    public var requiresClutch: Bool = true

    /// The false-positive brake for `requiresClutch == false`: since there's no clutch hold left
    /// to gate entry into "armed," `enterConfidence`/`stayConfidence` are raised by this amount
    /// (clamped to ≤0.95) before being compared against any candidate — composed on top of
    /// whatever `SensitivityTrim`/`LowLightPolicy` already produced, exactly the way those two
    /// compose with each other today. Only takes effect while `requiresClutch` is `false`; has no
    /// effect otherwise.
    public var clutchOffConfidenceBoost: Double = 0.15

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
    /// M3 Task 6: a `var`, not a `let` — `setTuning(_:)` below lets `PipelineCore` swap tuning
    /// (e.g. `LowLightPolicy.adjusted(...)`) on a low-light state flip WITHOUT recreating the
    /// engine. Recreating would reset `state`, `armingStartAt`, `debounceGesture`/`debounceCount`,
    /// `lastFiredAt` (every gesture's cooldown ledger), and `lastArmedAt` — i.e. it would silently
    /// disarm the user's clutch and clear every cooldown the instant the room dims or brightens,
    /// which is exactly the kind of surprise arbitration exists to prevent. Swapping `tuning` in
    /// place changes only the numbers future `ingest`/`ingestPreDebounced` calls compare against;
    /// every other piece of engine state — and therefore every cooldown/armed-window/debounce
    /// already in flight — survives the swap untouched.
    private var tuning: ArbitrationTuning

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

    /// `tuning.enterConfidence`, raised by `tuning.clutchOffConfidenceBoost` (clamped to ≤0.95)
    /// whenever `tuning.requiresClutch` is `false` — see that field's doc comment. Returns
    /// `tuning.enterConfidence` unchanged while the clutch is required, so every clutch-on code
    /// path (`processArmed`, and `ingestPreDebounced` while `requiresClutch` is `true`) behaves
    /// identically whether it reads this or `tuning.enterConfidence` directly.
    private var effectiveEnterConfidence: Double {
        guard !tuning.requiresClutch else { return tuning.enterConfidence }
        return min(tuning.enterConfidence + tuning.clutchOffConfidenceBoost, 0.95)
    }

    /// `tuning.stayConfidence`'s counterpart to `effectiveEnterConfidence` above.
    private var effectiveStayConfidence: Double {
        guard !tuning.requiresClutch else { return tuning.stayConfidence }
        return min(tuning.stayConfidence + tuning.clutchOffConfidenceBoost, 0.95)
    }

    public init(tuning: ArbitrationTuning = ArbitrationTuning()) {
        self.tuning = tuning
        if !tuning.requiresClutch {
            state = .armed(windowEndsAt: .infinity)
        }
    }

    /// Replaces the tuning used by every subsequent `ingest`/`ingestPreDebounced` call.
    ///
    /// If `requiresClutch` is unchanged by this swap, `state`, the arming clock, the in-progress
    /// debounce, and every gesture's cooldown ledger are left exactly as they were — see
    /// `tuning`'s doc comment for why swapping in place (rather than recreating the engine)
    /// matters. If `requiresClutch` itself flips (the clutch setting being toggled at runtime),
    /// every counter/ledger is cleared and `state` is set to the correct initial state for the new
    /// mode (off → `.armed(windowEndsAt: .infinity)`; on → `.disarmed`) — exactly as if the engine
    /// had been freshly constructed with this tuning — since neither an in-progress debounce nor a
    /// cooldown ledger accumulated under one mode is meaningful under the other.
    ///
    /// Callers driving this from outside a single-threaded context must serialize their own calls
    /// (e.g. via an owning actor) the same way `ingest` itself requires; this method does no
    /// locking of its own.
    public func setTuning(_ tuning: ArbitrationTuning) {
        let requiresClutchChanged = tuning.requiresClutch != self.tuning.requiresClutch
        self.tuning = tuning
        guard requiresClutchChanged else { return }
        clearLedger()
        state = tuning.requiresClutch ? .disarmed : .armed(windowEndsAt: .infinity)
    }

    /// Returns the engine to its mode's initial state — `.disarmed` while `requiresClutch` is
    /// `true`, `.armed(windowEndsAt: .infinity)` while it's `false` — with every counter cleared,
    /// as if newly constructed with the current tuning.
    public func reset() {
        clearLedger()
        state = tuning.requiresClutch ? .disarmed : .armed(windowEndsAt: .infinity)
    }

    /// Shared by `reset()` and `setTuning(_:)`'s mode-flip path: clears every piece of ledger state
    /// (the arming clock, the in-progress debounce, the per-gesture cooldown map, and the
    /// most-recent-arming timestamp) without touching `state` itself — callers set `state` to
    /// whatever's correct for their situation immediately after.
    private func clearLedger() {
        armingStartAt = nil
        debounceGesture = nil
        debounceCount = 0
        lastFiredAt = [:]
        lastArmedAt = nil
    }

    /// Feed exactly one sample per inference frame (nil = nothing classified this frame).
    /// Returns a fired event, or nil. Mutates `state`.
    public func ingest(_ candidate: GestureCandidate?, at now: TimeInterval) -> GestureEvent? {
        guard tuning.requiresClutch else {
            return processClutchOff(candidate, now: now)
        }

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
        guard candidate.confidence >= effectiveEnterConfidence else { return nil }
        guard !GestureCatalog.entry(for: candidate.gesture).isReserved else { return nil }

        let gesture = candidate.gesture

        // While `requiresClutch` is `false` no arming ever happens, so `lastArmedAt` stays `nil`
        // forever (see `clearLedger()`/`processClutch`) — this guard is naturally a no-op in that
        // mode, exactly matching the brief: "postArmSuppression ... does not apply (no arm ever
        // happens)."
        if gesture == .fistToOpen, let lastArmedAt, now - lastArmedAt < tuning.postArmSuppression {
            return nil
        }

        let cooldown = Self.repeatableGestures.contains(gesture) ? tuning.repeatCooldown : tuning.cooldown
        if let last = lastFiredAt[gesture], now - last < cooldown - Self.cooldownEpsilon {
            return nil
        }

        lastFiredAt[gesture] = now
        state = tuning.requiresClutch ? .armed(windowEndsAt: now + tuning.commandWindow) : .armed(windowEndsAt: .infinity)
        return GestureEvent(gesture: gesture, timestamp: now)
    }

    /// M3 Task 9: called by an owning engine (`TacitEngine`) once per frame while a `HoldTracker`
    /// hold is active, so the command window can never expire out from under a held gesture — a
    /// "point to speak" dictation session can run far longer than `tuning.commandWindow` without
    /// silently disarming mid-hold (which would leave the eventual key-up with no armed session
    /// to route through). No-op unless `state` is currently `.armed`: a hold only ever begins
    /// while armed (see `HoldTracker.ingest`'s doc comment — `began` requires a `fired` event,
    /// which itself only ever comes from an armed fire), so a call arriving while `.disarmed`/
    /// `.arming` means the window has already lapsed and there's nothing left to extend — the
    /// caller's own ended-path handling (not this method) is what reconciles that. Touches only
    /// `windowEndsAt`; never perturbs the cooldown ledger, debounce, or arming bookkeeping.
    public func extendWindow(at now: TimeInterval) {
        // While `requiresClutch` is `false` the window is already `.infinity` and never expires —
        // extending it to a finite `now + commandWindow` here would be a regression, not a no-op,
        // so this guards on `tuning.requiresClutch` too (not just `case .armed`).
        guard case .armed = state, tuning.requiresClutch else { return }
        state = .armed(windowEndsAt: now + tuning.commandWindow)
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

    // MARK: - Clutch-optional phase (`tuning.requiresClutch == false`)

    /// `ingest`'s entire entry point while `tuning.requiresClutch` is `false` — no arming, no
    /// disarming, no window expiry: `state` stays `.armed(windowEndsAt: .infinity)` for the whole
    /// call. Debounce/hysteresis/per-gesture-cooldown logic mirrors `processArmed` above, using
    /// `effectiveEnterConfidence`/`effectiveStayConfidence` (the clutch-off trust brake) in place
    /// of the raw `tuning` values, with two differences from `processArmed`:
    ///
    /// 1. `looseFist`/`openPalm` (`GestureCatalog...isReserved`) are simply ignored — no event, no
    ///    debounce reset, no disarm (there's no clutch left to disarm). `looseFist` already fell
    ///    through harmlessly whether reserved or not (it's never `debounceGesture`-tracked as a
    ///    fireable gesture), but `openPalm` is the meaningful change: `processArmed` disarms on a
    ///    completed `openPalm` debounce, which would be wrong here — there's nothing to disarm
    ///    into, and doing so would just silently re-implement a clutch nobody asked for.
    /// 2. A fire re-affirms `.armed(windowEndsAt: .infinity)`, not a finite `now + commandWindow`
    ///    window — there is nothing to extend; the window was never going to expire either way.
    private func processClutchOff(_ candidate: GestureCandidate?, now: TimeInterval) -> GestureEvent? {
        guard let candidate else {
            debounceGesture = nil
            debounceCount = 0
            return nil
        }

        guard !GestureCatalog.entry(for: candidate.gesture).isReserved else { return nil }

        if candidate.gesture == debounceGesture {
            guard candidate.confidence >= effectiveStayConfidence else {
                debounceGesture = nil
                debounceCount = 0
                return nil
            }
            debounceCount += 1
        } else {
            guard candidate.confidence >= effectiveEnterConfidence else {
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

        if let last = lastFiredAt[gesture], now - last < tuning.cooldown - Self.cooldownEpsilon {
            return nil
        }

        lastFiredAt[gesture] = now
        state = .armed(windowEndsAt: .infinity)
        return GestureEvent(gesture: gesture, timestamp: now)
    }
}
