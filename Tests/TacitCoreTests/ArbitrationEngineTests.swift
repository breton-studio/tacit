import Foundation
import Testing
@testable import TacitCore

/// Feeds `frames` consecutive inference-frame samples (dt apart, starting at `from`) into `engine`.
/// `gesture == nil` means "nothing classified this frame." Returns every fired event, in order.
@discardableResult
func feed(
    _ engine: ArbitrationEngine,
    gesture: GestureID?,
    conf: Double,
    from: TimeInterval,
    frames: Int,
    dt: TimeInterval = 1.0 / 15.0
) -> [GestureEvent] {
    var events: [GestureEvent] = []
    for i in 0..<frames {
        let t = from + Double(i) * dt
        let candidate = gesture.map { GestureCandidate(gesture: $0, confidence: conf, timestamp: t) }
        if let event = engine.ingest(candidate, at: t) {
            events.append(event)
        }
    }
    return events
}

// MARK: 1. Sustained looseFist arms the clutch, and only the clutch: never emits an event.

@Test func sustainedFistArmsWithoutEvent() {
    let e = ArbitrationEngine()
    let events = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8) // 8/15s > 0.4s clutchHold
    #expect(events.isEmpty)
    guard case .armed = e.state else {
        Issue.record("expected armed, got \(e.state)")
        return
    }
}

// MARK: 2. Releasing the fist mid-arming returns to disarmed; arming(progress:) exposes 0..1 meanwhile.

@Test func fistReleaseMidArmingReturnsToDisarmed() {
    let e = ArbitrationEngine()
    let dt = 1.0 / 15.0
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 3) // ~0.13s, well under 0.4s hold
    guard case .arming(let progress) = e.state else {
        Issue.record("expected arming, got \(e.state)")
        return
    }
    #expect(progress > 0 && progress < 1)

    _ = feed(e, gesture: nil, conf: 0, from: 3 * dt, frames: 1)
    #expect(e.state == .disarmed)
}

// MARK: 3. Armed + debounced openPalm -> immediate disarm, no event.

@Test func armedOpenPalmDisarmsWithoutEvent() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else {
        Issue.record("expected armed, got \(e.state)")
        return
    }

    let events = feed(e, gesture: .openPalm, conf: 0.9, from: 1.0, frames: 3)
    #expect(events.isEmpty)
    #expect(e.state == .disarmed)
}

// MARK: 4. Armed + non-reserved candidate debounced -> fires exactly once; window extends.

@Test func armedGestureFiresOnceAfterDebounce() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8) // 8/15 s > 0.4 s -> armed
    guard case .armed = e.state else { Issue.record("not armed"); return }
    let events = feed(e, gesture: .victory, conf: 0.8, from: 1.0, frames: 5)
    #expect(events == [GestureEvent(gesture: .victory, timestamp: events.first?.timestamp ?? -1)])

    guard case .armed(let windowEndsAt) = e.state else {
        Issue.record("expected still armed after firing, got \(e.state)")
        return
    }
    let fireTime = events[0].timestamp
    #expect(windowEndsAt == fireTime + ArbitrationTuning().commandWindow)
}

// MARK: 5. Hysteresis: a dip to stayConfidence still counts; a dip below stayConfidence resets the count.

@Test func hysteresisAllowsDipToStayConfidenceButResetsBelowIt() {
    let tuning = ArbitrationTuning()
    let dt = 1.0 / 15.0
    let t0 = 1.0

    // Scenario A: frames 1-2 >= enterConfidence, frame 3 between stayConfidence and enterConfidence
    // still counts toward the debounce -> fires on frame 3.
    let e1 = ArbitrationEngine()
    _ = feed(e1, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    _ = e1.ingest(GestureCandidate(gesture: .victory, confidence: 0.8, timestamp: t0), at: t0)
    _ = e1.ingest(GestureCandidate(gesture: .victory, confidence: 0.8, timestamp: t0 + dt), at: t0 + dt)
    let midConfidence = (tuning.stayConfidence + tuning.enterConfidence) / 2
    let thirdTime = t0 + 2 * dt
    let event = e1.ingest(
        GestureCandidate(gesture: .victory, confidence: midConfidence, timestamp: thirdTime),
        at: thirdTime
    )
    #expect(event == GestureEvent(gesture: .victory, timestamp: thirdTime))

    // Scenario B: frame 3 drops below stayConfidence -> resets the count; the very next
    // qualifying frame only restarts the count at 1, so it must not fire immediately.
    let e2 = ArbitrationEngine()
    _ = feed(e2, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    _ = e2.ingest(GestureCandidate(gesture: .victory, confidence: 0.8, timestamp: t0), at: t0)
    _ = e2.ingest(GestureCandidate(gesture: .victory, confidence: 0.8, timestamp: t0 + dt), at: t0 + dt)
    let belowStay = tuning.stayConfidence - 0.1
    let resetResult = e2.ingest(
        GestureCandidate(gesture: .victory, confidence: belowStay, timestamp: t0 + 2 * dt),
        at: t0 + 2 * dt
    )
    #expect(resetResult == nil)
    let noFireYet = e2.ingest(
        GestureCandidate(gesture: .victory, confidence: 0.8, timestamp: t0 + 3 * dt),
        at: t0 + 3 * dt
    )
    #expect(noFireYet == nil)
}

// MARK: 6. Cooldown suppresses a re-fire of the same gesture even if it re-debounces.

@Test func cooldownSuppressesRefireOfSameGesture() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    let firstEvents = feed(e, gesture: .victory, conf: 0.9, from: 1.0, frames: 3)
    #expect(firstEvents.count == 1)

    // Re-debounce the same gesture well within the 0.8s cooldown window.
    let refireStart = firstEvents[0].timestamp + 0.1
    let secondEvents = feed(e, gesture: .victory, conf: 0.9, from: refireStart, frames: 3)
    #expect(secondEvents.isEmpty)
}

// MARK: 7. No candidates until windowEndsAt -> auto-disarm.

@Test func windowExpiryAutoDisarms() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let windowEndsAt) = e.state else {
        Issue.record("expected armed, got \(e.state)")
        return
    }
    let event = e.ingest(nil, at: windowEndsAt + 0.01)
    #expect(event == nil)
    #expect(e.state == .disarmed)
}

// MARK: 8. Disarmed: non-clutch candidates never fire (Midas-touch defense).

@Test func disarmedNonClutchCandidatesNeverFire() {
    let e = ArbitrationEngine()
    let events = feed(e, gesture: .victory, conf: 0.95, from: 0, frames: 10)
    #expect(events.isEmpty)
    #expect(e.state == .disarmed)
}

// MARK: 9. reset() -> disarmed, all counters cleared (including per-gesture cooldown).

@Test func resetClearsStateAndCounters() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    let firstEvents = feed(e, gesture: .victory, conf: 0.9, from: 1.0, frames: 3)
    #expect(firstEvents.count == 1)

    e.reset()
    #expect(e.state == .disarmed)

    // If reset cleared the cooldown map, re-arming and re-debouncing the same gesture
    // immediately afterwards must fire again.
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 2.0, frames: 8)
    let events = feed(e, gesture: .victory, conf: 0.9, from: 3.0, frames: 3)
    #expect(events.count == 1)
}

// MARK: - `ingestPreDebounced` (Task 21 controller ruling R1)

// MARK: 10. Fires once when armed, above enterConfidence.

@Test func preDebouncedFiresOnceWhenArmed() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    let t = 1.0
    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) == GestureEvent(gesture: .thumbIndexTap, timestamp: t))
}

// MARK: 11. Respects the per-gesture cooldown shared with `ingest`.

@Test func preDebouncedRespectsCooldown() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)

    let first = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: 1.0)
    #expect(e.ingestPreDebounced(first, at: 1.0) != nil)

    // Well within the 0.8s cooldown window.
    let second = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: 1.1)
    #expect(e.ingestPreDebounced(second, at: 1.1) == nil)
}

// MARK: 12. Silent while disarmed or arming — never arms/disarms itself.

@Test func preDebouncedSilentWhenDisarmed() {
    let e = ArbitrationEngine()
    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.95, timestamp: 0)
    #expect(e.ingestPreDebounced(candidate, at: 0) == nil)
    #expect(e.state == .disarmed)
}

@Test func preDebouncedSilentWhileArming() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 2) // well under clutchHold
    guard case .arming = e.state else { Issue.record("expected arming, got \(e.state)"); return }

    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.95, timestamp: 0.1)
    #expect(e.ingestPreDebounced(candidate, at: 0.1) == nil)
}

// MARK: 13. Silent past the window's end, and silent below `enterConfidence`.

@Test func preDebouncedSilentAtOrAfterWindowEnd() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let windowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.95, timestamp: windowEndsAt)
    #expect(e.ingestPreDebounced(candidate, at: windowEndsAt) == nil)
}

@Test func preDebouncedSilentBelowEnterConfidence() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    let belowEnter = ArbitrationTuning().enterConfidence - 0.1
    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: belowEnter, timestamp: 1.0)
    #expect(e.ingestPreDebounced(candidate, at: 1.0) == nil)
}

// MARK: 14. Extends `windowEndsAt` to `now + commandWindow` on fire, same as a normal `ingest` fire.

@Test func preDebouncedExtendsWindow() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)

    let t = 1.0
    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) != nil)

    guard case .armed(let windowEndsAt) = e.state else {
        Issue.record("expected still armed after firing, got \(e.state)")
        return
    }
    #expect(windowEndsAt == t + ArbitrationTuning().commandWindow)
}

// MARK: 15. Reserved gestures (looseFist/openPalm) never fire through this path, even armed.

@Test func preDebouncedIgnoresReservedGestures() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    for gesture: GestureID in [.looseFist, .openPalm] {
        let candidate = GestureCandidate(gesture: gesture, confidence: 0.95, timestamp: 1.0)
        #expect(e.ingestPreDebounced(candidate, at: 1.0) == nil)
    }
}

// MARK: 16. Same-frame tie: a static event completing its debounce on the EXACT frame a
// momentary candidate fires via `ingestPreDebounced` — matching `PipelineCore.process`'s
// documented precedence (ingest static first, then pre-debounced; if both return an event, the
// momentary one is the pipeline's effective/reported event, but the static fire's cooldown
// ledger entry — recorded inside `ingest`, before `ingestPreDebounced` is ever called — is never
// undone).

@Test func sameFrameTieMomentaryWinsButStaticCooldownStillConsumed() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    let dt = 1.0 / 15.0
    let t0 = 1.0
    // Drive `.victory` through its 3-frame debounce; the third frame is where `ingest` fires.
    _ = e.ingest(GestureCandidate(gesture: .victory, confidence: 0.9, timestamp: t0), at: t0)
    _ = e.ingest(GestureCandidate(gesture: .victory, confidence: 0.9, timestamp: t0 + dt), at: t0 + dt)
    let tieTime = t0 + 2 * dt
    let staticEvent = e.ingest(GestureCandidate(gesture: .victory, confidence: 0.9, timestamp: tieTime), at: tieTime)
    #expect(staticEvent == GestureEvent(gesture: .victory, timestamp: tieTime))

    // On the SAME frame (identical timestamp, and — mirroring `PipelineCore.process`'s order —
    // called immediately after the static `ingest` above), a momentary candidate also fires
    // through the separate pre-debounced path.
    let momentaryCandidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: tieTime)
    let momentaryEvent = e.ingestPreDebounced(momentaryCandidate, at: tieTime)
    #expect(momentaryEvent == GestureEvent(gesture: .thumbIndexTap, timestamp: tieTime))

    // (a) The pipeline's documented precedence (`preDebouncedEvent ?? staticEvent`) reports the
    // momentary event as this frame's effective one.
    let effectiveEvent = momentaryEvent ?? staticEvent
    #expect(effectiveEvent?.gesture == .thumbIndexTap)

    // (b) The static gesture's cooldown ledger entry was still recorded by `ingest` above — even
    // though the momentary event is what the pipeline reports — so re-driving `.victory` through
    // a fresh debounce immediately afterward (well within the 0.8s cooldown) fires nothing.
    let refireEvents = feed(e, gesture: .victory, conf: 0.9, from: tieTime + dt, frames: 3)
    #expect(refireEvents.isEmpty)

    // (c) Neither call armed/disarmed the engine — it's still armed throughout.
    guard case .armed = e.state else {
        Issue.record("expected still armed after the tie, got \(e.state)")
        return
    }
}

// MARK: - Repeatable-gesture cooldown (rotate/scroll ticks; Task 4)

// MARK: 17. Repeatable gesture ticks spaced beyond `repeatCooldown` (0.2s) all fire.

@Test func repeatableTicksBeyondRepeatCooldownAllFire() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    var events: [GestureEvent] = []
    for i in 0..<5 {
        let t = 1.0 + Double(i) * 0.25
        let candidate = GestureCandidate(gesture: .wristRotateCW, confidence: 0.9, timestamp: t)
        if let event = e.ingestPreDebounced(candidate, at: t) {
            events.append(event)
        }
    }
    #expect(events.count == 5)
}

// MARK: 18. Repeatable gesture ticks spaced at 0.1s (under `repeatCooldown`) throttle: a tick only
// fires once at least `repeatCooldown - cooldownEpsilon` has elapsed since the last fire. Ticks
// land at t = 1.0, 1.1, 1.2, 1.3, 1.4; measured from the last *fire* (not the last tick):
//   tick 0 (t=1.0): nothing fired yet -> fires. last = 1.0.
//   tick 1 (t=1.1): 1.1 - 1.0 = 0.10000000000000009 < 0.2 - eps -> throttled.
//   tick 2 (t=1.2): 1.2 - 1.0 = 0.19999999999999996 (Double noise on `1.0 + 2*0.1`), which is
//     NOT < 0.2 - 1e-9 (~0.199999999) -> the epsilon slack lets this clear the cooldown -> fires.
//     (Without the epsilon this frame would be wrongly throttled — see the boundary test below.)
//     last = 1.2.
//   tick 3 (t=1.3): 1.3 - 1.2 = 0.10000000000000009 < 0.2 - eps -> throttled.
//   tick 4 (t=1.4): 1.4 - 1.2 = 0.19999999999999996, NOT < 0.2 - eps (same noise/epsilon reasoning
//     as tick 2) -> fires. last = 1.4.
// Verified against the actual `Double` arithmetic (not assumed) since `TimeInterval` accumulation
// via repeated `+0.1` doesn't land on an exact 0.2s boundary.
@Test func repeatableTicksUnderRepeatCooldownThrottleToComputedPattern() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    var fired: [Bool] = []
    for i in 0..<5 {
        let t = 1.0 + Double(i) * 0.1
        let candidate = GestureCandidate(gesture: .wristRotateCW, confidence: 0.9, timestamp: t)
        fired.append(e.ingestPreDebounced(candidate, at: t) != nil)
    }
    #expect(fired == [true, false, true, false, true])
}

// MARK: 18b. Boundary case in isolation: two ticks constructed to land exactly `repeatCooldown`
// (0.2s) apart via literals `1.0` and `1.2` (not accumulated addition) still hit the same `Double`
// representation noise — `1.2 - 1.0 == 0.19999999999999996`, a hair under `0.2` — so without the
// epsilon slack this would be wrongly throttled. With it, the second tick fires.
@Test func repeatableTickExactlyAtRepeatCooldownBoundaryFires() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    let t0 = 1.0
    let t1 = 1.2
    #expect(t1 - t0 == 0.19999999999999996) // documents the exact noise this test guards against

    let first = GestureCandidate(gesture: .wristRotateCW, confidence: 0.9, timestamp: t0)
    #expect(e.ingestPreDebounced(first, at: t0) != nil)

    let second = GestureCandidate(gesture: .wristRotateCW, confidence: 0.9, timestamp: t1)
    #expect(e.ingestPreDebounced(second, at: t1) != nil)
}

// MARK: 19. A non-repeatable momentary gesture still uses the 0.8s `cooldown`, not `repeatCooldown`
// — ticks 0.25s apart fire at t = 1.0 (nothing fired yet) and then not again until the elapsed
// time since that fire reaches 0.8s, which happens at t = 2.0 (4 * 0.25s later); the three ticks in
// between (1.25, 1.5, 1.75) are all still within the 0.8s window and are throttled.
@Test func nonRepeatableMomentaryStillUsesFullCooldown() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    var fired: [Bool] = []
    for i in 0..<5 {
        let t = 1.0 + Double(i) * 0.25
        let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: t)
        fired.append(e.ingestPreDebounced(candidate, at: t) != nil)
    }
    #expect(fired == [true, false, false, false, true])
}

// MARK: 20. Each accepted repeatable tick extends `windowEndsAt` to `now + commandWindow`, same
// as any other `ingestPreDebounced` fire.

@Test func repeatableTicksExtendWindow() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    for i in 0..<3 {
        let t = 1.0 + Double(i) * 0.25
        let candidate = GestureCandidate(gesture: .wristRotateCW, confidence: 0.9, timestamp: t)
        #expect(e.ingestPreDebounced(candidate, at: t) != nil)
        guard case .armed(let windowEndsAt) = e.state else {
            Issue.record("expected still armed after tick, got \(e.state)")
            return
        }
        #expect(windowEndsAt == t + ArbitrationTuning().commandWindow)
    }
}

// MARK: 21. Repeatable-gesture ticks while disarmed do nothing — the existing invariant
// (`ingestPreDebounced` is silent outside `.armed`) holds unchanged for the new repeatable set.

@Test func repeatableTicksSilentWhenDisarmed() {
    let e = ArbitrationEngine()
    let candidate = GestureCandidate(gesture: .twoFingerScrollUp, confidence: 0.95, timestamp: 0)
    #expect(e.ingestPreDebounced(candidate, at: 0) == nil)
    #expect(e.state == .disarmed)
}

// MARK: - Post-arm `.fistToOpen` suppression (controller fix, M3 Task 5 follow-up)
//
// The clutch arms by holding `.looseFist`; the arming fist's OWN subsequent opening into
// whatever the user does next (release into a tap, a swipe, or just relaxing the hand) is not
// itself a deliberate `.fistToOpen` gesture — without this suppression, EVERY clutch arm would
// masquerade as one. A `.fistToOpen` performed later in the SAME armed session, once
// `ArbitrationTuning.postArmSuppression` (default 0.6s) has elapsed since arming, is the
// deliberate mid-session case and must keep firing normally.
//
// Each test below extracts the actual arming instant from `windowEndsAt - commandWindow` rather
// than assuming a specific arming frame index — `feed`'s 8-frame `.looseFist` hold can complete
// arming on either of its last two frames depending on `Double` rounding of `i * dt`, so reading
// it back off `state` is the only robust way to anchor test timestamps to it.

@Test func fistToOpenSuppressedShortlyAfterArming() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let windowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }
    let armedAt = windowEndsAt - ArbitrationTuning().commandWindow

    // 0.2s after arming: well inside the default 0.6s postArmSuppression window.
    let t = armedAt + 0.2
    let candidate = GestureCandidate(gesture: .fistToOpen, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) == nil)

    // Suppressed, not just silent: no cooldown ledger entry was written, so a later fire (past
    // the suppression window here too) is not somehow throttled by this attempt.
    let laterT = armedAt + 0.8
    let laterCandidate = GestureCandidate(gesture: .fistToOpen, confidence: 0.9, timestamp: laterT)
    #expect(e.ingestPreDebounced(laterCandidate, at: laterT) == GestureEvent(gesture: .fistToOpen, timestamp: laterT))
}

@Test func fistToOpenFiresOnceSuppressionWindowElapses() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let windowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }
    let armedAt = windowEndsAt - ArbitrationTuning().commandWindow

    // 0.8s after arming: past the default 0.6s postArmSuppression window.
    let t = armedAt + 0.8
    let candidate = GestureCandidate(gesture: .fistToOpen, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) == GestureEvent(gesture: .fistToOpen, timestamp: t))
}

@Test func fistToOpenFiresNormallyMidSessionWellPastSuppression() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    // A deliberate fist-to-open several seconds into the same armed session — far past the
    // arming instant, the case this suppression must never touch.
    let t = 3.0
    let candidate = GestureCandidate(gesture: .fistToOpen, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) == GestureEvent(gesture: .fistToOpen, timestamp: t))
}

@Test func postArmSuppressionDoesNotAffectOtherMomentaryGestures() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let windowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }
    let armedAt = windowEndsAt - ArbitrationTuning().commandWindow

    // Same shortly-after-arming timing as the suppressed `.fistToOpen` case above, but a
    // different gesture: the suppression must be scoped to `.fistToOpen` only.
    let t = armedAt + 0.2
    let candidate = GestureCandidate(gesture: .thumbIndexTap, confidence: 0.9, timestamp: t)
    #expect(e.ingestPreDebounced(candidate, at: t) == GestureEvent(gesture: .thumbIndexTap, timestamp: t))
}

// MARK: - extendWindow (M3 Task 9)

@Test func extendWindowExtendsTheCommandWindowWhileArmed() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let originalWindowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    let extendAt = originalWindowEndsAt - 0.1 // just before the window would otherwise expire
    e.extendWindow(at: extendAt)

    guard case .armed(let extendedWindowEndsAt) = e.state else { Issue.record("expected still armed"); return }
    #expect(extendedWindowEndsAt == extendAt + ArbitrationTuning().commandWindow)
    #expect(extendedWindowEndsAt > originalWindowEndsAt)
}

@Test func extendWindowIsANoOpWhenDisarmed() {
    let e = ArbitrationEngine()
    #expect(e.state == .disarmed)
    e.extendWindow(at: 5.0)
    #expect(e.state == .disarmed)
}

@Test func extendWindowIsANoOpWhileArming() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 3) // mid-arming, not yet armed
    guard case .arming = e.state else { Issue.record("expected arming, got \(e.state)"); return }
    e.extendWindow(at: 1.0)
    guard case .arming = e.state else {
        Issue.record("extendWindow must not arm the clutch while arming, got \(e.state)")
        return
    }
}

@Test func extendWindowKeepsTheWindowOpenPastItsOriginalExpiry() {
    let e = ArbitrationEngine()
    _ = feed(e, gesture: .looseFist, conf: 0.9, from: 0, frames: 8)
    guard case .armed(let originalWindowEndsAt) = e.state else { Issue.record("expected armed, got \(e.state)"); return }

    // Extend repeatedly, well before each successive expiry, simulating a long hold.
    var t = originalWindowEndsAt - 0.1
    for _ in 0..<20 {
        e.extendWindow(at: t)
        t += ArbitrationTuning().commandWindow - 1.0
    }
    // One final extension right before feeding, so the fresh debounce below has the full
    // `commandWindow` of margin to complete in (rather than whatever sliver was left after the
    // loop's last step) — the loop above is what proves repeated extension survives well past
    // the original expiry; this final call just sets up a clean window for the assertion itself.
    e.extendWindow(at: t)

    // Long after the ORIGINAL window would have expired, a fresh candidate still fires — the
    // window never lapsed because it kept being extended.
    let events = feed(e, gesture: .victory, conf: 0.9, from: t, frames: 5)
    #expect(!events.isEmpty)
    #expect(t > originalWindowEndsAt + 10) // sanity: genuinely well past the original expiry
}
