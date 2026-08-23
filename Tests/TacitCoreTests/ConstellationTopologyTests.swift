import Foundation
import Testing
@testable import TacitCore

@Test func exactlyTwentyBones() {
    #expect(ConstellationTopology.bones.count == 20)
}

@Test func everyJointAppearsInAtLeastOneBone() {
    var seen = Set<HandJoint>()
    for (a, b) in ConstellationTopology.bones {
        seen.insert(a)
        seen.insert(b)
    }
    for joint in HandJoint.allCases {
        #expect(seen.contains(joint), "\(joint) does not appear in any bone")
    }
}

@Test func noDuplicateBonesOrderInsensitive() {
    var seen = Set<Set<HandJoint>>()
    for (a, b) in ConstellationTopology.bones {
        let key = Set([a, b])
        #expect(!seen.contains(key), "duplicate bone: \(a)-\(b)")
        seen.insert(key)
    }
}
