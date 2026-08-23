import Foundation

public enum Finger: CaseIterable, Sendable {
    case thumb, index, middle, ring, little
}

public enum HandGeometry {
    /// wrist→middleMCP distance; the normalization unit. nil if either joint missing.
    public static func palmSize(_ frame: LandmarkFrame) -> Double? {
        guard let wrist = frame.point(.wrist), let middleMCP = frame.point(.middleMCP) else {
            return nil
        }
        return distance(wrist, middleMCP)
    }

    /// tip farther from wrist than PIP (or, for the thumb, MP) by `margin`. nil if joints missing.
    public static func isFingerExtended(_ finger: Finger, in frame: LandmarkFrame, margin: Double = 1.15) -> Bool? {
        guard let wrist = frame.point(.wrist) else { return nil }

        let tipJoint: HandJoint
        let referenceJoint: HandJoint
        switch finger {
        case .thumb:
            tipJoint = .thumbTip
            referenceJoint = .thumbMP
        case .index:
            tipJoint = .indexTip
            referenceJoint = .indexPIP
        case .middle:
            tipJoint = .middleTip
            referenceJoint = .middlePIP
        case .ring:
            tipJoint = .ringTip
            referenceJoint = .ringPIP
        case .little:
            tipJoint = .littleTip
            referenceJoint = .littlePIP
        }

        guard let tip = frame.point(tipJoint), let reference = frame.point(referenceJoint) else {
            return nil
        }

        return distance(wrist, tip) > margin * distance(wrist, reference)
    }

    /// Euclidean distance between two joints divided by palmSize. nil if missing.
    public static func normalizedDistance(_ a: HandJoint, _ b: HandJoint, in frame: LandmarkFrame) -> Double? {
        guard let pointA = frame.point(a), let pointB = frame.point(b),
              let size = palmSize(frame), size > 0 else {
            return nil
        }
        return distance(pointA, pointB) / size
    }

    /// mean confidence over present joints (0 if none)
    public static func meanConfidence(_ frame: LandmarkFrame) -> Double {
        let confidences = frame.joints.values.map(\.confidence)
        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private static func distance(_ a: JointPoint, _ b: JointPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
