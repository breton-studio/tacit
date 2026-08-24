import Foundation
import Testing
@testable import TacitCore

// MARK: - Synthetic motion helpers

/// A closed thumb-index pinch (`SyntheticHand.pinch(.index, closed: true)`), with both the
/// thumb-tip and index-tip shifted by the same `(dx, dy)` — moving the pinch point while leaving
/// the thumb-index separation (and therefore the pinch's "closed" reading) untouched.
///
/// Base positions: indexTip = (0.32, 0.65), thumbTip = (0.315, 0.645) (0.005 inside the index tip
/// on both axes, per `SyntheticHand.pinch`'s doc comment). Their midpoint — the tracked pinch
/// point — starts at (0.3175, 0.6475) and moves by exactly `(dx, dy)` since both endpoints shift
/// identically. Palm size (wrist->middleMCP) is 0.15, unaffected by this shift.
private func pinchAt(dx: Double, dy: Double, t: TimeInterval) -> LandmarkFrame {
    var frame = SyntheticHand.pinch(.index, closed: true, t: t)
    if let thumb = frame.point(.thumbTip) {
        frame.joints[.thumbTip] = JointPoint(x: thumb.x + dx, y: thumb.y + dy, confidence: thumb.confidence)
    }
    if let index = frame.point(.indexTip) {
        frame.joints[.indexTip] = JointPoint(x: index.x + dx, y: index.y + dy, confidence: index.confidence)
    }
    return frame
}

// Shared arithmetic: palm size is 0.15 for every `SyntheticHand` pose. `PinchDragDetector`'s
// translation floor is 0.4 palm-units = 0.06 raw units; a raw shift of `dx` (with dy = 0) moves
// the pinch-point midpoint by exactly `dx` (both tracked tips shift by the same amount), so
// `dx / 0.15` is the travel in palm-units. `PinchDragDetector(minHold: 0.25)` is the default.

@Test func pinchHeldPastMinHoldThenTranslatedEmitsOnePinchDragOnce() {
    var detector = PinchDragDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        pinchAt(dx: 0, dy: 0, t: 0.00),   // closes: startPoint recorded, elapsed 0, travel 0
        pinchAt(dx: 0, dy: 0, t: 0.10),   // held, stationary: elapsed 0.10 < minHold (0.25) -- nil
        pinchAt(dx: 0, dy: 0, t: 0.30),   // held 0.30s (>= 0.25) but travel still 0 (< 0.4) -- nil
        // Translates dx = 0.075: travel = 0.075 / 0.15 = 0.5 palm-units (>= 0.4). Elapsed from
        // close (t=0) is 0.35s (>= 0.25). Both conditions first hold simultaneously here.
        pinchAt(dx: 0.075, dy: 0, t: 0.35),
        pinchAt(dx: 0.075, dy: 0, t: 0.45), // still held, already emitted: latched silent
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .pinchDrag)
}

@Test func subMinHoldTapLikePinchAndReleaseEmitsNothing() {
    var detector = PinchDragDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        pinchAt(dx: 0, dy: 0, t: 0.00),                            // closes
        SyntheticHand.pinch(.index, closed: false, t: 0.15),       // releases at 0.15s (< minHold 0.25)
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    // This is exactly PinchTapDetector's territory: held only 0.15s, well inside its
    // maxTapDuration (0.6s), and released before ever crossing minHold -- pinchDrag has nothing
    // to say about it.
    #expect(emitted.isEmpty)
}

@Test func releaseResetsSoASecondEngagementCanEmitAgain() {
    var detector = PinchDragDetector()
    var emitted: [GestureCandidate] = []

    let frames: [LandmarkFrame] = [
        // First engagement: held + translated, emits once.
        pinchAt(dx: 0, dy: 0, t: 0.00),
        pinchAt(dx: 0.075, dy: 0, t: 0.30), // elapsed 0.30 >= 0.25, travel 0.5 >= 0.4 -- emits
        SyntheticHand.pinch(.index, closed: false, t: 0.40), // release: resets
        // Second engagement, independent of the first, same shape.
        pinchAt(dx: 0, dy: 0, t: 0.50),
        pinchAt(dx: 0.075, dy: 0, t: 0.80), // elapsed 0.30 >= 0.25, travel 0.5 >= 0.4 -- emits again
    ]
    for frame in frames {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .pinchDrag })
}
