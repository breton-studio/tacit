import Foundation

public enum TacitCoreInfo {
    public static let version = "0.1.0"
}

public enum HandJoint: String, Codable, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

extension HandJoint: CodingKeyRepresentable {}

public struct JointPoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double, confidence: Double
    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public enum Handedness: String, Codable, Sendable {
    case left, right, unknown
}

public struct LandmarkFrame: Codable, Equatable, Sendable {
    public var timestamp: TimeInterval
    public var joints: [HandJoint: JointPoint]   // absent = below confidence floor
    public var handedness: Handedness

    public init(timestamp: TimeInterval, joints: [HandJoint: JointPoint], handedness: Handedness) {
        self.timestamp = timestamp
        self.joints = joints
        self.handedness = handedness
    }

    public func point(_ joint: HandJoint) -> JointPoint? {
        joints[joint]
    }
}

public enum GestureID: String, Codable, CaseIterable, Sendable {
    // Workhorses (spec gestures 1–8; report #9 split into two directions)
    case thumbIndexTap, thumbMiddleTap, indexPoint, victory, thumbsUp
    case looseFist, openPalm, thumbRingPinkyTap
    case thumbSwipeForward, thumbSwipeBackward
    // Occasional (M3)
    case swipeLeft, swipeRight, swipeUp, swipeDown, fistToOpen, pinchDrag, wristRotate, twoFingerScroll
    // Deliberate (M4)
    case palmPush, wave, twoHandFrame
}

public struct GestureCandidate: Equatable, Sendable {
    public var gesture: GestureID, confidence: Double, timestamp: TimeInterval
    public init(gesture: GestureID, confidence: Double, timestamp: TimeInterval) {
        self.gesture = gesture
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public struct GestureEvent: Equatable, Sendable {
    public var gesture: GestureID, timestamp: TimeInterval
    public init(gesture: GestureID, timestamp: TimeInterval) {
        self.gesture = gesture
        self.timestamp = timestamp
    }
}
