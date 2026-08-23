import Foundation
import Testing
@testable import TacitCore

/// Returns a copy of `frame` with every joint's confidence overridden to `confidence`.
/// (No SyntheticHand low-confidence variant exists; build one by remapping a pose's joints.)
private func withUniformConfidence(_ frame: LandmarkFrame, confidence: Double) -> LandmarkFrame {
    var joints = frame.joints
    for (key, point) in joints {
        joints[key] = JointPoint(x: point.x, y: point.y, confidence: confidence)
    }
    return LandmarkFrame(timestamp: frame.timestamp, joints: joints, handedness: frame.handedness)
}

@Test func openPalmClassifiesAsOpenPalm() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.openPalm(t: 1.5)
    let candidate = classifier.classify(frame)
    #expect(candidate?.gesture == .openPalm)
    #expect(candidate?.timestamp == 1.5)
    #expect(candidate?.confidence == HandGeometry.meanConfidence(frame))
}

@Test func looseFistClassifiesAsLooseFist() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.looseFist(t: 2.5)
    let candidate = classifier.classify(frame)
    #expect(candidate?.gesture == .looseFist)
    #expect(candidate?.timestamp == 2.5)
    #expect(candidate?.confidence == HandGeometry.meanConfidence(frame))
}

@Test func typingHandClassifiesAsNil() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.typingHand()
    #expect(classifier.classify(frame) == nil)
}

@Test func emptyFrameClassifiesAsNil() {
    let classifier = StaticPoseClassifier()
    let frame = LandmarkFrame(timestamp: 0, joints: [:], handedness: .unknown)
    #expect(classifier.classify(frame) == nil)
}

@Test func lowConfidenceOpenPalmClassifiesAsNil() {
    let classifier = StaticPoseClassifier()
    let frame = withUniformConfidence(SyntheticHand.openPalm(), confidence: 0.3)
    #expect(classifier.classify(frame) == nil)
}

// MARK: - Task 12: indexPoint, victory, thumbsUp

@Test func indexPointClassifiesAsIndexPoint() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.indexPoint(t: 3.5)
    let candidate = classifier.classify(frame)
    #expect(candidate?.gesture == .indexPoint)
    #expect(candidate?.timestamp == 3.5)
    #expect(candidate?.confidence == HandGeometry.meanConfidence(frame))
}

@Test func victoryClassifiesAsVictory() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.victory(t: 4.5)
    let candidate = classifier.classify(frame)
    #expect(candidate?.gesture == .victory)
    #expect(candidate?.timestamp == 4.5)
    #expect(candidate?.confidence == HandGeometry.meanConfidence(frame))
}

@Test func thumbsUpClassifiesAsThumbsUp() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.thumbsUp(t: 5.5)
    let candidate = classifier.classify(frame)
    #expect(candidate?.gesture == .thumbsUp)
    #expect(candidate?.timestamp == 5.5)
    #expect(candidate?.confidence == HandGeometry.meanConfidence(frame))
}

// MARK: - Task 12: confusable checks (priority order: victory > indexPoint > thumbsUp > looseFist > openPalm)

@Test func victoryDoesNotClassifyAsIndexPoint() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.victory()
    #expect(classifier.classify(frame)?.gesture != .indexPoint)
}

@Test func thumbsUpDoesNotClassifyAsLooseFist() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.thumbsUp()
    #expect(classifier.classify(frame)?.gesture != .looseFist)
}

@Test func typingHandStillClassifiesAsNilWithFullPoseSet() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.typingHand()
    #expect(classifier.classify(frame) == nil)
}

// MARK: - Review fix: nil joints must FAIL a curled requirement, not silently pass it.

@Test func indexPointWithMissingMiddleJointsClassifiesAsNilNotIndexPoint() {
    let classifier = StaticPoseClassifier()
    var frame = SyntheticHand.indexPoint()
    for joint: HandJoint in [.middleMCP, .middlePIP, .middleDIP, .middleTip] {
        frame.joints[joint] = nil
    }
    // Middle's curled-ness is indeterminate (joints missing), not confirmed curled — must not
    // silently satisfy indexPoint's "middle curled" requirement.
    #expect(classifier.classify(frame) == nil)
}

// MARK: - Review fix: a true victory shape with tips pulled together isn't victory, and per
// priority order (indexPoint requires middle curled, which this frame's middle is not — its
// extension geometry is unchanged, only the middle tip's position moved) it isn't indexPoint
// either. The rules imply nil.

@Test func victoryShapedHandWithTipsTogetherIsNotVictory() {
    let classifier = StaticPoseClassifier()
    var frame = SyntheticHand.victory()
    frame.joints[.middleTip] = JointPoint(x: 0.45, y: 0.65, confidence: 0.9)
    let spread = HandGeometry.normalizedDistance(.indexTip, .middleTip, in: frame)!
    #expect(spread < 0.45) // sanity: this frame really does violate victory's spread requirement
    #expect(classifier.classify(frame)?.gesture != .victory)
    #expect(classifier.classify(frame) == nil)
}

// MARK: - Review fix: a pinch-tap's fingers-extended frames must not read as `.openPalm` — that's
// the arbitration engine's disarm signal, so wiring taps in would disarm the command window on
// every tap. A held/closed pinch has the thumb collapsed onto a target fingertip, but the old
// "all Finger.allCases extended" rule still saw the thumb as "extended" (far from the wrist, even
// though it's right next to the index tip) — so it misclassified as an open palm.

@Test func closedPinchDoesNotClassifyAsOpenPalm() {
    let classifier = StaticPoseClassifier()
    let closed = SyntheticHand.pinch(.index, closed: true)
    // Sanity: this really is the "thumb collapsed onto index" shape the bug hinged on.
    #expect(HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: closed)! < 0.35)
    #expect(classifier.classify(closed)?.gesture != .openPalm)
    #expect(classifier.classify(closed) == nil)
}

@Test func openPalmStillClassifiesAsOpenPalmWithThumbIndexDistanceClearingPinchOpenThreshold() {
    let classifier = StaticPoseClassifier()
    let frame = SyntheticHand.openPalm()
    // Sanity: a genuine open palm's thumb really is spread away from the index finger, clearing
    // pinchOpenThreshold (0.60) — this is what distinguishes it from a held pinch.
    #expect(HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame)! > ClassifierTuning().pinchOpenThreshold)
    #expect(classifier.classify(frame)?.gesture == .openPalm)
}

// `SyntheticHand.pinch(_, closed: false)` is documented ("Open-palm spot (already set via
// extendedThumb above)") — and verified below — to produce a `LandmarkFrame` bit-identical to
// `SyntheticHand.openPalm()`: the thumb rests at the same neutral, spread-open coordinate in both.
// It genuinely IS an open palm shape (there is no pinch signal at all, positive or negative, in
// this frame), so it correctly classifies as `.openPalm` — same input, same output, by
// construction. It is `.thumbIndexTap`'s open bookend frames, not a distinct "about to pinch"
// shape.
@Test func openPinchBookendFrameIsIdenticalToOpenPalmAndClassifiesAsOpenPalm() {
    let classifier = StaticPoseClassifier()
    let open = SyntheticHand.pinch(.index, closed: false)
    let openPalm = SyntheticHand.openPalm()
    #expect(open.joints == openPalm.joints)
    #expect(classifier.classify(open)?.gesture == .openPalm)
}
