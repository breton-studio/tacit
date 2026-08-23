import Foundation
import Testing
@testable import TacitCore

/// A `looseFist` frame with `thumbTip.x` overridden, at time `t`. Fingers stay curled (fisted);
/// only the thumb moves, simulating a thumb-swipe while the hand stays clenched.
private func fistedThumbAt(x: Double, t: TimeInterval) -> LandmarkFrame {
    var frame = SyntheticHand.looseFist(t: t)
    let tip = frame.point(.thumbTip)!
    frame.joints[.thumbTip] = JointPoint(x: x, y: tip.y, confidence: tip.confidence)
    return frame
}

/// An `openPalm` frame (fingers extended) with `thumbTip.x` overridden, at time `t`.
private func extendedThumbAt(x: Double, t: TimeInterval) -> LandmarkFrame {
    var frame = SyntheticHand.openPalm(t: t)
    let tip = frame.point(.thumbTip)!
    frame.joints[.thumbTip] = JointPoint(x: x, y: tip.y, confidence: tip.confidence)
    return frame
}

/// `looseFist`'s wrist is at x=0.5 and its resting thumbTip.x (0.38) is to the *left* of the
/// wrist, so decreasing x moves the thumb further away from the wrist ("forward" by this
/// detector's documented convention) and increasing x moves it back toward the wrist
/// ("backward"). Palm size (wrist→middleMCP) is 0.15, so a travel of 0.4 palm-units is a raw
/// x-delta of 0.06.

@Test func thumbMovingAwayFromWristEmitsForwardSwipe() {
    var detector = ThumbSwipeDetector()
    let xs: [Double] = [0.38, 0.36, 0.34, 0.32] // moving left: away from wrist at x=0.5
    var emitted: [GestureCandidate] = []
    for (i, x) in xs.enumerated() {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbSwipeForward)
}

@Test func thumbMovingTowardWristEmitsBackwardSwipe() {
    var detector = ThumbSwipeDetector()
    let xs: [Double] = [0.38, 0.40, 0.42, 0.44] // moving right: toward wrist at x=0.5
    var emitted: [GestureCandidate] = []
    for (i, x) in xs.enumerated() {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbSwipeBackward)
}

@Test func sameTravelWithFingersExtendedEmitsNothing() {
    var detector = ThumbSwipeDetector()
    let xs: [Double] = [0.28, 0.26, 0.24, 0.22] // same 0.06 raw delta, openPalm's resting thumbTip.x is 0.28
    var emitted: [GestureCandidate] = []
    for (i, x) in xs.enumerated() {
        if let candidate = detector.ingest(extendedThumbAt(x: x, t: TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.isEmpty)
}

@Test func sameTravelOverTooLongADurationEmitsNothing() {
    var detector = ThumbSwipeDetector()
    let samples: [(Double, TimeInterval)] = [
        (0.38, 0), (0.36, 0.4), (0.34, 0.8), (0.32, 1.2),
    ]
    var emitted: [GestureCandidate] = []
    for (x, t) in samples {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: t)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.isEmpty)
}

@Test func noMovementEmitsNothing() {
    var detector = ThumbSwipeDetector()
    var emitted: [GestureCandidate] = []
    for i in 0..<4 {
        if let candidate = detector.ingest(fistedThumbAt(x: 0.38, t: TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.isEmpty)
}

@Test func requiresResetBeforeSecondEmission() {
    var detector = ThumbSwipeDetector()
    var emitted: [GestureCandidate] = []

    // First swipe: away from wrist, crosses minTravel at t=0.3.
    let firstSwipe: [Double] = [0.38, 0.36, 0.34, 0.32]
    for (i, x) in firstSwipe.enumerated() {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)

    // Keep drifting the same direction without ever going stationary or extending fingers:
    // must NOT re-fire until an explicit reset (stationary thumb, or fingers extended) happens.
    for (i, x) in [0.30, 0.28, 0.26].enumerated() {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: 0.4 + TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)

    // Reset: fingers extend (openPalm) for two consecutive frames — one frame of "bad" posture
    // alone is forgiven as jitter tolerance (see `badFrameToleratedMidSwipeStillEmits` /
    // `twoConsecutiveBadFramesResetTracking` below), so a real reset needs two in a row.
    _ = detector.ingest(SyntheticHand.openPalm(t: 0.8))
    _ = detector.ingest(SyntheticHand.openPalm(t: 0.85))

    // Second swipe, fresh.
    let secondSwipe: [Double] = [0.26, 0.24, 0.22, 0.20]
    for (i, x) in secondSwipe.enumerated() {
        if let candidate = detector.ingest(fistedThumbAt(x: x, t: 0.9 + TimeInterval(i) * 0.1)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 2)
    #expect(emitted.last?.gesture == .thumbSwipeForward)
}

// MARK: - Review fix: one-frame jitter tolerance on the curled/no-pinch precondition.

@Test func singleBadFrameMidSwipeIsForgivenAndTheSwipeStillEmits() {
    var detector = ThumbSwipeDetector()
    var emitted: [GestureCandidate] = []

    for frame in [
        fistedThumbAt(x: 0.38, t: 0),
        fistedThumbAt(x: 0.36, t: 0.1),
        SyntheticHand.openPalm(t: 0.2), // single noise frame: detector jitter, not a real posture change
        fistedThumbAt(x: 0.34, t: 0.3),
        fistedThumbAt(x: 0.32, t: 0.4),
    ] {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbSwipeForward)
}

@Test func twoConsecutiveBadFramesResetTrackingAndSuppressTheSwipe() {
    var detector = ThumbSwipeDetector()
    var emitted: [GestureCandidate] = []

    for frame in [
        fistedThumbAt(x: 0.38, t: 0),
        fistedThumbAt(x: 0.36, t: 0.1),
        SyntheticHand.openPalm(t: 0.2),
        SyntheticHand.openPalm(t: 0.3), // second consecutive bad frame: genuine reset
        fistedThumbAt(x: 0.34, t: 0.4),
        fistedThumbAt(x: 0.32, t: 0.5),
    ] {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // Post-reset travel (0.34 -> 0.32, one palm-unit short of minTravel) never crosses the
    // threshold, and the pre-reset travel (0.38 -> 0.36) was too small either — so nothing fires.
    #expect(emitted.isEmpty)
}
