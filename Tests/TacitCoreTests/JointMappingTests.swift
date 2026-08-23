import Foundation
import Testing
@testable import TacitCore

@Test func visionNameRoundTripsForAllJoints() {
    for joint in HandJoint.allCases {
        let name = joint.visionName
        #expect(HandJoint.fromVisionName(name) == joint)
    }
}

@Test func allVisionNamesAreUnique() {
    let names = HandJoint.allCases.map(\.visionName)
    #expect(Set(names).count == HandJoint.allCases.count)
}

@Test func fromVisionNameReturnsNilForUnknownString() {
    #expect(HandJoint.fromVisionName("not-a-real-joint") == nil)
}
