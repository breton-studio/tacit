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
