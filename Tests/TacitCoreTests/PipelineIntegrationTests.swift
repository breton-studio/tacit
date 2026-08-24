import Foundation
import Testing
@testable import TacitCore

/// A small, pure-`TacitCore` harness mirroring `PipelineCore.process`'s per-frame algorithm
/// (`Sources/Tacit/TacitEngine.swift`, Task 21 controller ruling R2) one level down from the real
/// pipeline: it starts from an already-detected `LandmarkFrame` (no Vision/`HandPoseDetector`
/// involved — that type lives in the `Tacit` app target, not `TacitCore`, and isn't reachable from
/// this test target) and runs the SAME per-frame precedence the production pipeline does:
///
/// 1. The static classifier's candidate is fed to `arbitration.ingest` first — the clutch/disarm
///    path, unchanged, always runs regardless of what any momentary detector does this frame.
/// 2. A momentary tap/swipe candidate (`tap ?? swipe`, matching the production `??` short-circuit)
///    goes through the separate `arbitration.ingestPreDebounced` entry point.
/// 3. If both return an event on the same frame, the momentary one wins — it's returned and the
///    static event is ledger-dropped (its cooldown/window bookkeeping inside `ingest` already
///    happened and is never undone; only which `GestureEvent` this frame reports differs).
private struct Harness {
    let classifier = StaticPoseClassifier()
    var tapDetector = PinchTapDetector()
    var swipeDetector = ThumbSwipeDetector()
    let arbitration = ArbitrationEngine()

    mutating func ingest(_ frame: LandmarkFrame) -> GestureEvent? {
        let staticEvent = arbitration.ingest(classifier.classify(frame), at: frame.timestamp)

        let momentary = tapDetector.ingest(frame) ?? swipeDetector.ingest(frame)
        let preDebouncedEvent = momentary.flatMap { arbitration.ingestPreDebounced($0, at: frame.timestamp) }

        return preDebouncedEvent ?? staticEvent
    }
}

private let dt: TimeInterval = 1.0 / 15.0

/// Feeds enough `looseFist` frames (8 @ 15Hz ≈ 0.53s > the 0.4s `clutchHold`) to arm the clutch,
/// asserting no event fires along the way, and returns the timestamp right after the last one.
@discardableResult
private func armClutch(_ harness: inout Harness) -> TimeInterval {
    var t: TimeInterval = 0
    for i in 0..<8 {
        t = Double(i) * dt
        #expect(harness.ingest(SyntheticHand.looseFist(t: t)) == nil)
    }
    guard case .armed = harness.arbitration.state else {
        Issue.record("expected armed after the clutch hold, got \(harness.arbitration.state)")
        return t
    }
    return t + dt
}

// MARK: 1. Clutch-then-tap: exactly one `.thumbIndexTap` fires, and the engine never disarms.

@Test func armedThumbIndexTapFiresOnceWithoutDisarming() {
    var harness = Harness()
    let t0 = armClutch(&harness)

    // pinch(.index, closed: false) → closed (2 frames) → open — a `.thumbIndexTap` tap sequence.
    // The open bookend frames classify as `.openPalm` (see `StaticPoseClassifier.matchOpenPalm`'s
    // pinch guard), but the disarm debounce needs 3 CONSECUTIVE `.openPalm` frames and the closed
    // frames in between classify as nil (the same pinch guard blocks `matchOpenPalm` AND
    // `matchLooseFist` while pinched), so the count never accumulates far enough to disarm.
    let frames = [
        SyntheticHand.pinch(.index, closed: false, t: t0),
        SyntheticHand.pinch(.index, closed: true, t: t0 + dt),
        SyntheticHand.pinch(.index, closed: true, t: t0 + 2 * dt),
        SyntheticHand.pinch(.index, closed: false, t: t0 + 3 * dt),
    ]

    var events: [GestureEvent] = []
    for frame in frames {
        if let event = harness.ingest(frame) { events.append(event) }
    }

    #expect(events.count == 1)
    #expect(events.first?.gesture == .thumbIndexTap)
    #expect(events.first?.timestamp == frames.last?.timestamp)

    guard case .armed = harness.arbitration.state else {
        Issue.record("expected still armed after the tap, got \(harness.arbitration.state)")
        return
    }
}

// MARK: 2. Clutch-then-victory: held 3+ frames while armed fires exactly one `.victory` event.

@Test func armedVictoryHeldFiresExactlyOnce() {
    var harness = Harness()
    let t0 = armClutch(&harness)

    var events: [GestureEvent] = []
    for i in 0..<5 {
        let t = t0 + Double(i) * dt
        if let event = harness.ingest(SyntheticHand.victory(t: t)) { events.append(event) }
    }

    #expect(events.count == 1)
    #expect(events.first?.gesture == .victory)

    guard case .armed = harness.arbitration.state else {
        Issue.record("expected still armed after victory fired, got \(harness.arbitration.state)")
        return
    }
}
