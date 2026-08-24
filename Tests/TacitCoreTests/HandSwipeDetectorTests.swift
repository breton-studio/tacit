import Foundation
import Testing
@testable import TacitCore

// MARK: - Synthetic motion helpers

/// Translates every present joint of `frame` by `(dx, dy)` and stamps it with timestamp `t`.
/// This is how whole-hand-swipe motion paths are built from `SyntheticHand.openPalm()` /
/// `.looseFist()`: a rigid translation preserves every inter-joint distance, so palm size
/// (wrist -> middleMCP = 0.15, per `SyntheticHand`'s doc comment) and the open/fisted pose read
/// stay exactly what they were pre-translation — only the palm center moves.
private func shift(_ frame: LandmarkFrame, dx: Double, dy: Double, t: TimeInterval) -> LandmarkFrame {
    var shifted = frame
    for (joint, point) in shifted.joints {
        shifted.joints[joint] = JointPoint(x: point.x + dx, y: point.y + dy, confidence: point.confidence)
    }
    shifted.timestamp = t
    return shifted
}

/// `frame` with `joint` deleted entirely, simulating a dropped/untracked joint for one frame.
private func droppingJoint(_ joint: HandJoint, from frame: LandmarkFrame) -> LandmarkFrame {
    var dropped = frame
    dropped.joints.removeValue(forKey: joint)
    return dropped
}

// Shared arithmetic for every test below (SyntheticHand's palm size is fixed at 0.15, and a rigid
// translation doesn't change it):
//   - HandSwipeDetector() defaults: minTravel = 1.2 palm-units, maxDuration = 0.45 s,
//     minMeanSpeed = 4.0 palm-units/s, dominanceRatio = 2.0.
//   - A raw displacement of 0.20 (in SyntheticHand's normalized 0..1 space) is
//     0.20 / 0.15 = 1.333 palm-units of travel -- comfortably over minTravel (1.2).
//   - Reaching that over 5 frames spanning 0.3 s (0, 0.075, 0.15, 0.225, 0.3) gives
//     mean speed 1.333 / 0.3 = 4.44 palm-units/s -- over minMeanSpeed (4.0).

// MARK: - Fast single-axis swipes

@Test func fastRightSwipeEmitsSwipeRightExactlyOnce() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...4 {
        let dx = Double(i) * 0.05 // 0, 0.05, 0.10, 0.15, 0.20
        let t = Double(i) * 0.075 // 0, 0.075, 0.15, 0.225, 0.3
        if let candidate = detector.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            emitted.append(candidate)
        }
    }

    // At i=4: travel = 0.20/0.15 = 1.333 palm-units (>= 1.2), elapsed = 0.3 s (<= 0.45),
    // meanSpeed = 1.333/0.3 = 4.44 palm-units/s (>= 4.0), dy = 0 so dominance is trivially
    // satisfied (minorAxis = 0). Increasing x -> .swipeRight.
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .swipeRight)
}

@Test func sameRightPathTooSlowEmitsNothing() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...4 {
        let dx = Double(i) * 0.05
        let t = Double(i) * 0.3 // 0, 0.3, 0.6, 0.9, 1.2 -- same path, 4x slower
        if let candidate = detector.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            emitted.append(candidate)
        }
    }

    // Even ignoring the rolling-window mechanics: total travel is still 1.333 palm-units, but
    // now spread over 1.2 s, giving mean speed 1.333/1.2 = 1.11 palm-units/s, far under the 4.0
    // minMeanSpeed floor. The window mechanics make this doubly certain: each 0.3 s sub-step
    // only advances travel by 0.05/0.15 = 0.333 palm-units (< 1.2 minTravel), and once elapsed
    // since the window's anchor exceeds maxDuration (0.45 s) the anchor slides forward to the
    // current frame, so travel never gets to accumulate past one 0.3 s step's worth anyway.
    #expect(emitted.isEmpty)
}

@Test func upSwipeEmitsSwipeUp() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...4 {
        let dy = Double(i) * 0.05
        let t = Double(i) * 0.075
        if let candidate = detector.ingest(shift(base, dx: 0, dy: dy, t: t)) {
            emitted.append(candidate)
        }
    }

    // Same arithmetic as the right-swipe case with axes swapped: travel = 1.333, meanSpeed =
    // 4.44, dx = 0 so dominance is trivial. y-up coordinates + increasing y -> .swipeUp.
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .swipeUp)
}

// MARK: - Negative shape checks

@Test func diagonalMotionWithoutAxisDominanceEmitsNothing() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...4 {
        let d = Double(i) * 0.05
        let t = Double(i) * 0.075
        if let candidate = detector.ingest(shift(base, dx: d, dy: d, t: t)) {
            emitted.append(candidate)
        }
    }

    // At i=4: dx = dy = 0.20/0.15 = 1.333 palm-units each. travel = sqrt(1.333^2 + 1.333^2)
    // = 1.885 (>= 1.2 minTravel), meanSpeed = 1.885/0.3 = 6.28 (>= 4.0 minMeanSpeed) -- travel
    // and speed both clear their floors easily. But majorAxis == minorAxis == 1.333, and
    // dominanceRatio requires majorAxis >= 2.0 * minorAxis i.e. 1.333 >= 2.667, which is false.
    // Dominance fails on every frame, so nothing ever emits.
    #expect(emitted.isEmpty)
}

@Test func fistedHandTranslationEmitsNothing() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    for i in 0...4 {
        let dx = Double(i) * 0.05
        let t = Double(i) * 0.075
        if let candidate = detector.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            emitted.append(candidate)
        }
    }

    // Identical travel/speed/dominance profile to the passing right-swipe, but the hand is
    // fisted throughout: 0 of the 4 non-thumb fingers read as extended (< 3 required), so every
    // single frame fails the open-ish precondition. A tracking window never gets a chance to
    // form (the very first frame is already "bad"), so nothing emits regardless of motion.
    #expect(emitted.isEmpty)
}

// MARK: - Settle and re-arm

@Test func settleThenSecondSwipeFiresAgain() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    // First swipe: identical to fastRightSwipeEmitsSwipeRightExactlyOnce, emits at t=0.3.
    for i in 0...4 {
        let dx = Double(i) * 0.05
        let t = Double(i) * 0.075
        if let candidate = detector.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)

    // Settle: 2 consecutive frames holding the exact same position as the last swipe frame.
    // Frame-to-frame motion is 0 palm-units (< 0.1 settle epsilon) both times, so after the
    // second one the detector re-anchors a fresh window right here (t=0.45, dx=0.20).
    _ = detector.ingest(shift(base, dx: 0.20, dy: 0, t: 0.375))
    _ = detector.ingest(shift(base, dx: 0.20, dy: 0, t: 0.45))
    #expect(emitted.count == 1)

    // Second swipe, fresh anchor at (dx: 0.20, t: 0.45): same 0.05-per-frame / 0.075 s-per-frame
    // shape as the first swipe, reaching dx=0.40 at t=0.75. travel = (0.40-0.20)/0.15 = 1.333,
    // elapsed = 0.75-0.45 = 0.3 s, meanSpeed = 4.44 -- identical arithmetic to the first swipe.
    for j in 1...4 {
        let dx = 0.20 + Double(j) * 0.05
        let t = 0.45 + Double(j) * 0.075
        if let candidate = detector.ingest(shift(base, dx: dx, dy: 0, t: t)) {
            emitted.append(candidate)
        }
    }

    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .swipeRight })
}

// MARK: - Jitter tolerance / reset discipline

@Test func singleDroppedJointFrameMidSwipeIsForgivenAndTheSwipeStillEmits() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        shift(base, dx: 0.00, dy: 0, t: 0.000),
        shift(base, dx: 0.05, dy: 0, t: 0.075),
        // Single noise frame: littleMCP dropped, so no palm center can be computed at all. This
        // is forgiven (tracking state -- the t=0 anchor -- is kept untouched) rather than
        // resetting the window.
        droppingJoint(.littleMCP, from: shift(base, dx: 0.075, dy: 0, t: 0.1125)),
        shift(base, dx: 0.10, dy: 0, t: 0.150),
        shift(base, dx: 0.15, dy: 0, t: 0.225),
        shift(base, dx: 0.20, dy: 0, t: 0.300),
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // Because the anchor was never disturbed, the final frame's math is identical to
    // fastRightSwipeEmitsSwipeRightExactlyOnce: travel = 1.333, elapsed = 0.3 s, meanSpeed =
    // 4.44 -- still crosses every threshold, exactly once.
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .swipeRight)
}

@Test func twoConsecutiveDroppedJointFramesResetTrackingAndSuppressTheSwipe() {
    var detector = HandSwipeDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        shift(base, dx: 0.00, dy: 0, t: 0.000),
        shift(base, dx: 0.05, dy: 0, t: 0.075),
        // Two consecutive bad frames: a genuine reset, not jitter.
        droppingJoint(.littleMCP, from: shift(base, dx: 0.075, dy: 0, t: 0.1125)),
        droppingJoint(.littleMCP, from: shift(base, dx: 0.0875, dy: 0, t: 0.1275)),
        shift(base, dx: 0.10, dy: 0, t: 0.150),
        shift(base, dx: 0.15, dy: 0, t: 0.225),
        shift(base, dx: 0.20, dy: 0, t: 0.300),
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // The reset means the dx=0.10, t=0.150 frame becomes the *new* anchor (there is no window
    // to re-anchor until the next good frame arrives). From there: at t=0.225, travel =
    // (0.15-0.10)/0.15 = 0.333 (< 1.2); at t=0.300, elapsed since the new anchor is
    // 0.300-0.150 = 0.15 s and travel = (0.20-0.10)/0.15 = 0.667 (< 1.2 minTravel). Neither the
    // pre-reset fragment (dx 0 -> 0.05, travel 0.333) nor the post-reset fragment ever crosses
    // minTravel, so nothing emits.
    #expect(emitted.isEmpty)
}

// MARK: - FistToOpenDetector

@Test func fistThenOpenWithinTransitionEmitsFistToOpen() {
    var detector = FistToOpenDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        SyntheticHand.looseFist(t: 0.0),
        SyntheticHand.looseFist(t: 0.1),
        SyntheticHand.looseFist(t: 0.2),
        SyntheticHand.openPalm(t: 0.6),
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // Elapsed is measured from the most recently seen fist frame (t=0.2) to the open frame
    // (t=0.6): 0.6-0.2 = 0.4 s, within the default maxTransition of 0.5 s.
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .fistToOpen)
}

@Test func fistThenOpenAfterTooLongEmitsNothing() {
    var detector = FistToOpenDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        SyntheticHand.looseFist(t: 0.0),
        SyntheticHand.looseFist(t: 0.1),
        SyntheticHand.looseFist(t: 0.2),
        SyntheticHand.openPalm(t: 1.0),
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // Elapsed from the last fist frame (t=0.2) to the open frame (t=1.0) is 0.8 s, over the
    // default maxTransition of 0.5 s.
    #expect(emitted.isEmpty)
}

@Test func fistToOpenRequiresLeavingOpenBeforeRearmingAFreshTransition() {
    var detector = FistToOpenDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        SyntheticHand.looseFist(t: 0.0),
        SyntheticHand.openPalm(t: 0.2), // first transition: emits
        SyntheticHand.openPalm(t: 0.3), // still open: must not re-emit
        SyntheticHand.looseFist(t: 0.4),
        SyntheticHand.openPalm(t: 0.6), // second, independent transition: emits again
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .fistToOpen })
}
