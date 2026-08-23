import Foundation
import Testing
@testable import TacitCore

@Test func landmarkFrameCodableRoundTrip() throws {
    let frame = LandmarkFrame(
        timestamp: 1.25,
        joints: [.wrist: JointPoint(x: 0.5, y: 0.2, confidence: 0.9),
                 .indexTip: JointPoint(x: 0.55, y: 0.8, confidence: 0.7)],
        handedness: .right)
    let data = try FixtureCodec.encode([frame])
    let decoded = try FixtureCodec.decode(data)
    #expect(decoded == [frame])
}

@Test func jointDictionaryEncodesAsStringKeyedObject() throws {
    let frame = LandmarkFrame(timestamp: 0,
        joints: [.wrist: JointPoint(x: 0, y: 0, confidence: 1)], handedness: .unknown)
    let json = String(decoding: try FixtureCodec.encode([frame]), as: UTF8.self)
    #expect(json.contains("\"wrist\""))   // dict keys, not tuple arrays
}

@Test func gestureIDHas21Cases() {
    #expect(GestureID.allCases.count == 21)
}

@Test func missingJointReturnsNil() {
    let frame = LandmarkFrame(timestamp: 0, joints: [:], handedness: .left)
    #expect(frame.point(.thumbTip) == nil)
}
