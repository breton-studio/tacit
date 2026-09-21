import Foundation
import Testing
@testable import TacitCore

@Test func calibrationDerivesPerSideRulesAndDetectorUsesHysteresis() throws {
    let input = KeyboardCalibrationInput(
        cameraID: "brio",
        cameraName: "Brio 500",
        cameraDeviceType: "external",
        typing: repeatedFrames(leftY: 0.65, rightY: 0.62),
        leftLift: repeatedFrames(leftY: 0.25, rightY: 0.62),
        rightLift: repeatedFrames(leftY: 0.65, rightY: 0.22)
    )
    let result = KeyboardHomeCalibrator.derive(from: input)
    let profile = try #require(try? result.get())

    #expect(profile.leftRule.direction == .lower)
    #expect(profile.rightRule.direction == .lower)
    #expect(profile.leftRule.separationAUC == 1)
    #expect(profile.rightRule.separationAUC == 1)

    var detector = KeyboardLiftDetector()
    let leftLift = frames(leftY: 0.25, rightY: 0.62, timestamp: 100)
    #expect(detector.ingest(leftLift, profile: profile) == .resting)
    #expect(detector.ingest(leftLift, profile: profile) == .resting)
    #expect(detector.ingest(leftLift, profile: profile) == .leftLifted)

    let resting = frames(leftY: 0.65, rightY: 0.62, timestamp: 101)
    #expect(detector.ingest(resting, profile: profile) == .leftLifted)
    #expect(detector.ingest(resting, profile: profile) == .leftLifted)
    #expect(detector.ingest(resting, profile: profile) == .resting)
}

@Test func restingHandCannotMakeLowQualityTargetPassCalibration() {
    let input = KeyboardCalibrationInput(
        cameraID: "brio",
        cameraName: "Brio 500",
        cameraDeviceType: "external",
        typing: repeatedFrames(leftY: 0.65, rightY: 0.62),
        leftLift: (0..<30).map { index in
            [
                hand(centerX: 0.3, centerY: 0.25, timestamp: Double(index), confidentJoints: 8),
                hand(centerX: 0.7, centerY: 0.62, timestamp: Double(index), confidentJoints: 21),
            ]
        },
        rightLift: repeatedFrames(leftY: 0.65, rightY: 0.22)
    )

    let result = KeyboardHomeCalibrator.derive(from: input)
    guard case .failure(.insufficientTargetVisibility(let side, let rate)) = result else {
        Issue.record("Expected target-hand visibility failure")
        return
    }
    #expect(side == .left)
    #expect(rate == 0)
}

@Test func staleProfileFailsClosed() throws {
    let input = KeyboardCalibrationInput(
        cameraID: "brio",
        cameraName: "Brio 500",
        cameraDeviceType: "external",
        typing: repeatedFrames(leftY: 0.65, rightY: 0.62),
        leftLift: repeatedFrames(leftY: 0.25, rightY: 0.62),
        rightLift: repeatedFrames(leftY: 0.65, rightY: 0.22)
    )
    var profile = try #require(try? KeyboardHomeCalibrator.derive(from: input).get())
    profile.schemaVersion = 0
    var detector = KeyboardLiftDetector()
    #expect(detector.ingest(frames(leftY: 0.25, rightY: 0.22), profile: profile) == .unavailable)
}

@Test func calibrationLearnsMirroredPhysicalToImageSideMapping() throws {
    let input = KeyboardCalibrationInput(
        cameraID: "mirrored-camera",
        cameraName: "Mirrored camera",
        cameraDeviceType: "external",
        typing: repeatedFrames(leftY: 0.65, rightY: 0.62),
        // Physical left appears on image-right; physical right appears on image-left.
        leftLift: repeatedFrames(leftY: 0.65, rightY: 0.22),
        rightLift: repeatedFrames(leftY: 0.25, rightY: 0.62)
    )
    let profile = try #require(try? KeyboardHomeCalibrator.derive(from: input).get())

    #expect(profile.leftRule.side == .right)
    #expect(profile.rightRule.side == .left)

    var detector = KeyboardLiftDetector()
    let physicalLeftLift = frames(leftY: 0.65, rightY: 0.22)
    #expect(detector.ingest(physicalLeftLift, profile: profile) == .resting)
    #expect(detector.ingest(physicalLeftLift, profile: profile) == .resting)
    #expect(detector.ingest(physicalLeftLift, profile: profile) == .leftLifted)
}

private func repeatedFrames(leftY: Double, rightY: Double) -> [[LandmarkFrame]] {
    (0..<30).map { index in
        frames(leftY: leftY, rightY: rightY, timestamp: Double(index) / 15)
    }
}

private func frames(leftY: Double, rightY: Double, timestamp: Double = 0) -> [LandmarkFrame] {
    [
        hand(centerX: 0.3, centerY: leftY, timestamp: timestamp, confidentJoints: 21),
        hand(centerX: 0.7, centerY: rightY, timestamp: timestamp, confidentJoints: 21),
    ]
}

private func hand(
    centerX: Double,
    centerY: Double,
    timestamp: Double,
    confidentJoints: Int
) -> LandmarkFrame {
    var joints: [HandJoint: JointPoint] = [:]
    for (index, joint) in HandJoint.allCases.enumerated() {
        let column = Double(index % 5 - 2) * 0.01
        let row = Double(index / 5 - 2) * 0.01
        joints[joint] = JointPoint(
            x: centerX + column,
            y: centerY + row,
            confidence: index < confidentJoints ? 0.95 : 0.4
        )
    }
    return LandmarkFrame(
        timestamp: timestamp,
        joints: joints,
        handedness: centerX < 0.5 ? .left : .right
    )
}
