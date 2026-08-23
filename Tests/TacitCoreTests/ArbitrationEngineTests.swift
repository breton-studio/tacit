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
