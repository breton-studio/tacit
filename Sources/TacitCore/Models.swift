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

extension HandJoint {
    /// Vision's `VNHumanHandPoseObservation.JointName` rawValue string for this joint.
    ///
    /// TacitCore imports Foundation only (no Vision), so these are plain string literals copied
    /// verbatim from `VNHumanHandPoseObservation.JointName.*.rawValue.rawValue`, printed via a
    /// throwaway scratch script that imported Vision — not guessed.
    public var visionName: String {
        switch self {
        case .wrist: "VNHLKWRI"
        case .thumbCMC: "VNHLKTCMC"
        case .thumbMP: "VNHLKTMP"
        case .thumbIP: "VNHLKTIP"
        case .thumbTip: "VNHLKTTIP"
        case .indexMCP: "VNHLKIMCP"
        case .indexPIP: "VNHLKIPIP"
        case .indexDIP: "VNHLKIDIP"
        case .indexTip: "VNHLKITIP"
        case .middleMCP: "VNHLKMMCP"
        case .middlePIP: "VNHLKMPIP"
        case .middleDIP: "VNHLKMDIP"
        case .middleTip: "VNHLKMTIP"
        case .ringMCP: "VNHLKRMCP"
        case .ringPIP: "VNHLKRPIP"
        case .ringDIP: "VNHLKRDIP"
        case .ringTip: "VNHLKRTIP"
        case .littleMCP: "VNHLKPMCP"
        case .littlePIP: "VNHLKPPIP"
        case .littleDIP: "VNHLKPDIP"
        case .littleTip: "VNHLKPTIP"
        }
    }

    /// Reverse lookup: Vision's `JointName` rawValue string back to a `HandJoint`, or `nil` if the
    /// string doesn't match any known joint.
    public static func fromVisionName(_ name: String) -> HandJoint? {
        visionNameToJoint[name]
    }

    private static let visionNameToJoint: [String: HandJoint] =
        Dictionary(uniqueKeysWithValues: HandJoint.allCases.map { ($0.visionName, $0) })
}

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
    // Occasional (M3; wrist-rotate and two-finger-scroll are each split into a directional pair —
    // report gestures #16/#17 split the same way #9 was)
    case swipeLeft, swipeRight, swipeUp, swipeDown, fistToOpen, pinchDrag
    case wristRotateCW, wristRotateCCW, twoFingerScrollUp, twoFingerScrollDown
    // 2026-08-24 ruling ("whole-hand swipes aren't being detected"): the app-switch job moves off
    // the four hand swipes (which stay recognized/bindable but ship disabled — see defaults
    // revision 7) onto an open-palm tilt: lean the open hand left or right, one tilt = one app.
    case palmTiltLeft, palmTiltRight
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
