import Foundation
import Testing
@testable import TacitCore

/// A small, pure-`TacitCore` harness mirroring `PipelineCore.process`'s per-frame algorithm
/// (`Sources/Tacit/TacitEngine.swift`, Task 21 controller ruling R2, extended by M3 Task 5) one
/// level down from the real pipeline: it starts from an already-detected `LandmarkFrame` (no
/// Vision/`HandPoseDetector` involved — that type lives in the `Tacit` app target, not
/// `TacitCore`, and isn't reachable from this test target) and runs the SAME per-frame precedence
/// the production pipeline does:
///
/// 1. The static classifier's candidate is fed to `arbitration.ingest` first — the clutch/disarm
///    path, unchanged, always runs regardless of what any momentary detector does this frame.
/// 2. A momentary candidate — `tap ?? thumbSwipe ?? handSwipe ?? fistToOpen ?? rotateTick ??
///    scrollTick`, matching `PipelineCore.process`'s `??` short-circuit chain exactly — goes
///    through the separate `arbitration.ingestPreDebounced` entry point. (`PinchDragDetector` has
///    no place here: it's preview-only, per plan ruling 2, and never appears in ANY production or
///    Harness momentary chain.)
/// 3. If both return an event on the same frame, the momentary one wins — it's returned and the
///    static event is ledger-dropped (its cooldown/window bookkeeping inside `ingest` already
///    happened and is never undone; only which `GestureEvent` this frame reports differs).
///
/// **Mirror-contract:** this struct and `PipelineCore.process` must stay in lockstep — any change
/// to one's precedence chain, detector set, or ordering needs the identical change made to the
/// other (and to `NegativeSuiteTests.replayThroughFullChain`, which runs the same chain over the
/// negative-suite streams). Diff them side by side before calling a pipeline-wiring change done.
private struct Harness {
    let classifier = StaticPoseClassifier()
    var tapDetector = PinchTapDetector()
    var swipeDetector = ThumbSwipeDetector()
    var handSwipeDetector = HandSwipeDetector()
    var fistToOpenDetector = FistToOpenDetector()
    var wristRotateDetector = WristRotateDetector()
    var twoFingerScrollDetector = TwoFingerScrollDetector()
    let arbitration = ArbitrationEngine()

    mutating func ingest(_ frame: LandmarkFrame) -> GestureEvent? {
        let staticEvent = arbitration.ingest(classifier.classify(frame), at: frame.timestamp)

        let momentary = tapDetector.ingest(frame)
            ?? swipeDetector.ingest(frame)
            ?? handSwipeDetector.ingest(frame)
            ?? fistToOpenDetector.ingest(frame)
            ?? wristRotateDetector.ingest(frame)
            ?? twoFingerScrollDetector.ingest(frame)
        let preDebouncedEvent = momentary.flatMap { arbitration.ingestPreDebounced($0, at: frame.timestamp) }

        return preDebouncedEvent ?? staticEvent
    }
}

private let dt: TimeInterval = 1.0 / 15.0

/// Feeds enough `looseFist` frames (8 @ 15Hz ≈ 0.53s > the 0.4s `clutchHold`) to arm the clutch,
/// asserting no event fires along the way, and returns a timestamp comfortably after the last
/// one for callers to build their own post-arm sequence from.
///
/// M3 Task 5 note on the gap size: `FistToOpenDetector` (wired into `Harness`'s momentary chain
/// like every other detector — it must keep tracking through the arming hold too, exactly like
/// `tapDetector`/`swipeDetector` already did) sees these 8 `looseFist` frames as a genuine fist
/// phase (`.fistSeen(lastAt: <last arming frame's timestamp>)`). If the very next frame a caller
/// feeds classifies as `.openPalm` (several fixtures' "open bookend" frames do) within its default
/// `maxTransition` (0.5 s) of that last arming frame, it reads — correctly, by the detector's own
/// documented contract — as a genuine fist-to-open transition and fires `.fistToOpen`. The
/// original `t + dt` gap (~0.067 s) was far inside that window and produced exactly that spurious
/// fire once `FistToOpenDetector` was wired in. `postArmGap` (0.6 s) clears `maxTransition`
/// with margin, so `FistToOpenDetector` sees `elapsed > maxTransition` on that next frame and
/// resets to `.idle` instead — without touching the detector's tuning or logic. The 4 s
/// `commandWindow` set on arming comfortably outlives this gap, so the engine is still `.armed`
/// however a caller uses the returned timestamp.
private let postArmGap: TimeInterval = 0.6

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
    return t + postArmGap
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

// MARK: - M3 Task 5: dynamic-layer integration (hand swipe, wrist rotate)

/// `SyntheticHand.looseFist()` with the thumb tip pulled onto the index tip (fully pinched).
/// Used only by `armedRotateSweep...` below to isolate `WristRotateDetector`'s ticks from every
/// OTHER detector earlier in the momentary precedence chain during a sustained rotation:
///   - `ThumbSwipeDetector` (precedence: tap > thumbSwipe > handSwipe > ...) requires the fisted
///     hand to have NO pinch engaged; pinning the thumb onto the index tip permanently fails that
///     precondition, so it never tracks or fires, however far the wrist turns.
///   - `StaticPoseClassifier.matchLooseFist` requires thumb-index distance to clear
///     `pinchCloseThreshold`; with the thumb pinned, `classify(_:)` returns nil for every frame
///     of the sweep — no `.looseFist` candidate reaches `arbitration.ingest`, so there's no static
///     event and no risk of disturbing the already-armed state.
///   - `HandSwipeDetector` and `FistToOpenDetector`'s own preconditions (open-ish / open-classified)
///     are already unsatisfiable by a fisted hand regardless of thumb position.
/// `WristRotateDetector` itself only inspects the four non-thumb fingers, so it's unaffected.
private func pinchedFist(t: TimeInterval = 0) -> LandmarkFrame {
    var frame = SyntheticHand.looseFist(t: t)
    if let indexTip = frame.point(.indexTip) {
        frame.joints[.thumbTip] = indexTip
    }
    return frame
}

// MARK: 3. Clutch-then-swipe: an armed, open-ish rightward swipe fires exactly one `.swipeRight`
// and leaves the engine armed.

@Test func armedRightSwipeFiresSwipeRightExactlyOnceWithoutDisarming() {
    var harness = Harness()
    let t0 = armClutch(&harness)

    // `threeFingerOpen` (not `openPalm`): open-ish enough for `HandSwipeDetector`'s ≥3-of-4
    // precondition, but invisible to `StaticPoseClassifier` (see that pose's doc comment) — an
    // `openPalm`-based swipe path would read as `.openPalm` on every one of these frames and trip
    // the arbitration engine's 3-consecutive-frame disarm debounce before the swipe's travel
    // threshold ever crosses. Same arithmetic as `HandSwipeDetectorTests.
    // fastRightSwipeEmitsSwipeRightExactlyOnce`: travel = 0.20/0.15 = 1.333 palm-units over
    // 0.3 s, meanSpeed = 4.44 palm-units/s — both clear `HandSwipeDetector()`'s defaults
    // (minTravel 1.2, minMeanSpeed 4.0).
    let base = SyntheticHand.threeFingerOpen()
    var events: [GestureEvent] = []
    for i in 0...4 {
        let dx = Double(i) * 0.05
        let t = t0 + Double(i) * 0.075
        if let event = harness.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            events.append(event)
        }
    }

    #expect(events.count == 1)
    #expect(events.first?.gesture == .swipeRight)

    guard case .armed = harness.arbitration.state else {
        Issue.record("expected still armed after the swipe, got \(harness.arbitration.state)")
        return
    }
}

// MARK: 4. Clutch-then-rotate: a 45° clockwise wrist-rotate sweep while armed fires exactly two
// `.wristRotateCW` ticks, honoring the 0.2 s repeat-cooldown floor.

@Test func armedFortyFiveDegreeRotateSweepEmitsExactlyTwoCWTicksRespectingRepeatCooldown() {
    var harness = Harness()
    let t0 = armClutch(&harness)
    let base = pinchedFist()

    // Same shape as `RotateScrollDetectorTests.fortyFiveDegreeClockwiseSweepEmitsExactlyTwoCWTicks`:
    // 5° of clockwise rotation per frame, 0.05 s apart. `WristRotateDetector()`'s default
    // tickArcDegrees (20°) crosses at i=4 (magnitude 20°, t = t0 + 0.20 s) and again at i=8
    // (magnitude 40°, t = t0 + 0.40 s) — a 0.20 s gap between the two ticks, exactly
    // `ArbitrationTuning.repeatCooldown`'s floor (compared with `cooldownEpsilon` slack in
    // `ArbitrationEngine`, so an exact 0.2 s gap reliably clears it rather than being swallowed by
    // floating-point noise). At i=9 (magnitude 45°) the tick level is still 2 (floor(45/20)) — no
    // third tick.
    var events: [GestureEvent] = []
    for i in 0...9 {
        let cumulative = Double(-5 * i)
        let t = t0 + Double(i) * 0.05
        if let event = harness.ingest(rotate(base, degrees: cumulative, t: t)) {
            events.append(event)
        }
    }

    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.gesture == .wristRotateCW })
    if events.count == 2 {
        #expect(events[1].timestamp - events[0].timestamp >= 0.2 - 1e-6, "ticks must be spaced at least the 0.2s repeat cooldown apart")
    }

    guard case .armed = harness.arbitration.state else {
        Issue.record("expected still armed after the rotate ticks, got \(harness.arbitration.state)")
        return
    }
}

// MARK: 5. Disarmed: the exact same swipe motion that fires while armed fires nothing at all.

@Test func disarmedRightSwipeFiresNothingAndStaysDisarmed() {
    var harness = Harness()
    let base = SyntheticHand.threeFingerOpen()

    var events: [GestureEvent] = []
    for i in 0...4 {
        let dx = Double(i) * 0.05
        let t = Double(i) * 0.075
        if let event = harness.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            events.append(event)
        }
    }

    // `ingestPreDebounced` requires `state` to already be `.armed`; while disarmed it rejects the
    // candidate outright regardless of the genuine swipe motion `HandSwipeDetector` recognizes —
    // no clutch, no dispatch, exactly the Midas-touch guarantee this pipeline exists to provide.
    #expect(events.isEmpty)

    guard case .disarmed = harness.arbitration.state else {
        Issue.record("expected to stay disarmed, got \(harness.arbitration.state)")
        return
    }
}
