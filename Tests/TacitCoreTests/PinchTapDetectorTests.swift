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
