import Foundation
import Testing
@testable import TacitCore

/// Builds an open→closed(2 frames)→open sequence for `finger`, spaced 0.05s apart starting at `t0`.
private func tapSequence(_ finger: Finger, t0: TimeInterval = 0) -> [LandmarkFrame] {
    [
        SyntheticHand.pinch(finger, closed: false, t: t0),
        SyntheticHand.pinch(finger, closed: true, t: t0 + 0.05),
        SyntheticHand.pinch(finger, closed: true, t: t0 + 0.10),
        SyntheticHand.pinch(finger, closed: false, t: t0 + 0.15),
    ]
}

@Test func indexPinchTapEmitsOnReleaseFrame() {
    var detector = PinchTapDetector()
    let frames = tapSequence(.index)
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbIndexTap)
    #expect(emitted.first?.timestamp == frames.last?.timestamp)
}

@Test func middlePinchTapEmitsThumbMiddleTap() {
    var detector = PinchTapDetector()
    let frames = tapSequence(.middle)
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbMiddleTap)
}

@Test func ringPinchTapEmitsThumbRingPinkyTap() {
    var detector = PinchTapDetector()
    let frames = tapSequence(.ring)
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbRingPinkyTap)
}

@Test func littlePinchTapEmitsThumbRingPinkyTap() {
    var detector = PinchTapDetector()
    let frames = tapSequence(.little)
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbRingPinkyTap)
}

@Test func pinchHeldLongerThanMaxTapDurationEmitsNothing() {
    var detector = PinchTapDetector(maxTapDuration: 0.6)
    let frames: [LandmarkFrame] = [
        SyntheticHand.pinch(.index, closed: false, t: 0),
        SyntheticHand.pinch(.index, closed: true, t: 0.1),
        SyntheticHand.pinch(.index, closed: true, t: 0.5),
        SyntheticHand.pinch(.index, closed: true, t: 1.0),
        SyntheticHand.pinch(.index, closed: false, t: 1.1),
    ]
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.isEmpty)
}

@Test func openFramesAloneEmitNothing() {
    var detector = PinchTapDetector()
    let frames = [
        SyntheticHand.pinch(.index, closed: false, t: 0),
        SyntheticHand.pinch(.index, closed: false, t: 0.1),
        SyntheticHand.pinch(.index, closed: false, t: 0.2),
    ]
    var emitted: [GestureCandidate] = []
    for frame in frames {
        if let candidate = detector.ingest(frame) {
            emitted.append(candidate)
        }
    }
    #expect(emitted.isEmpty)
}

// MARK: - Review fix: coverage gaps around state clearing.

@Test func failedOverDurationTapFollowedImmediatelyByValidTapStillEmitsTheValidOne() {
    var detector = PinchTapDetector(maxTapDuration: 0.6)
    var emitted: [GestureCandidate] = []

    // A held-too-long pinch: releases past maxTapDuration, so it must emit nothing...
    let failedTap: [LandmarkFrame] = [
        SyntheticHand.pinch(.index, closed: false, t: 0),
        SyntheticHand.pinch(.index, closed: true, t: 0.1),
        SyntheticHand.pinch(.index, closed: true, t: 1.0),
        SyntheticHand.pinch(.index, closed: false, t: 1.1),
    ]
    // ...immediately followed by a fresh, valid tap: state must be fully cleared by the failed
    // attempt's release, so this one emits normally.
    let validTap: [LandmarkFrame] = [
        SyntheticHand.pinch(.index, closed: true, t: 1.2),
        SyntheticHand.pinch(.index, closed: true, t: 1.25),
        SyntheticHand.pinch(.index, closed: false, t: 1.3),
    ]

    for frame in failedTap + validTap {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbIndexTap)
    #expect(emitted.first?.timestamp == 1.3)
}

@Test func midPinchJointDropoutReturnsToIdleAndTheNextTapStillWorks() {
    var detector = PinchTapDetector()
    var emitted: [GestureCandidate] = []

    // Establish a closed pinch on the index finger...
    _ = detector.ingest(SyntheticHand.pinch(.index, closed: false, t: 0))
    _ = detector.ingest(SyntheticHand.pinch(.index, closed: true, t: 0.1))

    // ...then the index finger's joints drop out entirely mid-pinch (a detection dropout), which
    // must abandon this pinch attempt and return to idle rather than getting stuck waiting for a
    // release distance it can no longer compute.
    var dropout = SyntheticHand.pinch(.index, closed: true, t: 0.2)
    for joint: HandJoint in [.indexMCP, .indexPIP, .indexDIP, .indexTip] {
        dropout.joints[joint] = nil
    }
    if let candidate = detector.ingest(dropout) { emitted.append(candidate) }

    // A fresh, complete tap sequence afterward must still work normally.
    for frame in [
        SyntheticHand.pinch(.middle, closed: false, t: 0.3),
        SyntheticHand.pinch(.middle, closed: true, t: 0.35),
        SyntheticHand.pinch(.middle, closed: false, t: 0.4),
    ] {
        if let candidate = detector.ingest(frame) { emitted.append(candidate) }
    }

    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .thumbMiddleTap)
}

@Test func detectorIsReusableAcrossSeparateTaps() {
    var detector = PinchTapDetector()
    var emitted: [GestureID] = []
    for frame in tapSequence(.index, t0: 0) {
        if let candidate = detector.ingest(frame) { emitted.append(candidate.gesture) }
    }
    for frame in tapSequence(.middle, t0: 1) {
        if let candidate = detector.ingest(frame) { emitted.append(candidate.gesture) }
    }
    #expect(emitted == [.thumbIndexTap, .thumbMiddleTap])
}
