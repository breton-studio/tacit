import Foundation
import TacitCore

// MARK: - Shared synthetic-motion helpers
//
// Task 5 (M3 pipeline wiring) consolidated these here: `shift` originated in
// `HandSwipeDetectorTests`, `rotate` in `RotateScrollDetectorTests` (each file had its own
// `private` copy), and `PipelineIntegrationTests` needed both for its armed-swipe/armed-rotate
// integration tests — a third call site made the duplication worth collapsing into one shared,
// non-private home. Behavior is unchanged from the original `private` versions.

/// Translates every present joint of `frame` by `(dx, dy)` and stamps it with timestamp `t`. This
/// is how whole-hand-swipe motion paths are built from `SyntheticHand.openPalm()` /
/// `.looseFist()` / `.threeFingerOpen()`: a rigid translation preserves every inter-joint
/// distance, so palm size (wrist→middleMCP = 0.15) and the open/fisted/partial pose reads stay
/// exactly what they were pre-translation — only the palm center moves.
func shift(_ frame: LandmarkFrame, dx: Double, dy: Double, t: TimeInterval) -> LandmarkFrame {
    var shifted = frame
    for (joint, point) in shifted.joints {
        shifted.joints[joint] = JointPoint(x: point.x + dx, y: point.y + dy, confidence: point.confidence)
    }
    shifted.timestamp = t
    return shifted
}

/// Rotates every present joint of `frame` by `degrees` around the wrist (standard math
/// convention: positive = counter-clockwise, using the y-up rotation matrix
/// `(x', y') = (x cosθ - y sinθ, x sinθ + y cosθ)` applied to each joint's wrist-relative offset),
/// and stamps it with timestamp `t`. Rotation is rigid, so it preserves every wrist-relative
/// distance — palm size and the fisted/open finger-extension reads are unaffected; only the
/// wrist→middleMCP vector's angle changes, by exactly `degrees`.
func rotate(_ frame: LandmarkFrame, degrees: Double, t: TimeInterval) -> LandmarkFrame {
    guard let wrist = frame.point(.wrist) else { return frame }
    var rotated = frame
    let theta = degrees * Double.pi / 180
    let cosT = cos(theta)
    let sinT = sin(theta)
    for (joint, point) in frame.joints {
        let dx = point.x - wrist.x
        let dy = point.y - wrist.y
        let newX = wrist.x + dx * cosT - dy * sinT
        let newY = wrist.y + dx * sinT + dy * cosT
        rotated.joints[joint] = JointPoint(x: newX, y: newY, confidence: point.confidence)
    }
    rotated.timestamp = t
    return rotated
}

/// `frame` with `joint` deleted entirely, simulating a dropped/untracked joint for one frame.
func droppingJoint(_ joint: HandJoint, from frame: LandmarkFrame) -> LandmarkFrame {
    var dropped = frame
    dropped.joints.removeValue(forKey: joint)
    return dropped
}

/// Builds full 21-joint `LandmarkFrame`s for canonical poses, used by every recognition test.
/// Test-target only: not part of TacitCore's public API.
///
/// Layout: wrist at (0.5, 0.2), palm size (wrist→middleMCP) = 0.15, all joint confidences 0.9.
/// Coordinates are normalized 0..1, origin lower-left, y up.
enum SyntheticHand {

    // MARK: - Point construction

    private static func jp(_ x: Double, _ y: Double) -> JointPoint {
        JointPoint(x: x, y: y, confidence: 0.9)
    }

    private static func frame(t: TimeInterval, _ joints: [HandJoint: JointPoint]) -> LandmarkFrame {
        LandmarkFrame(timestamp: t, joints: joints, handedness: .right)
    }

    // MARK: - Shared finger position sets

    /// Straight, extended finger chains (used by openPalm, and reused for indexPoint/pinch bases).
    private static var extendedNonThumb: [HandJoint: JointPoint] {
        [
            .indexMCP: jp(0.32, 0.35), .indexPIP: jp(0.32, 0.50), .indexDIP: jp(0.32, 0.58), .indexTip: jp(0.32, 0.65),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.50), .middleDIP: jp(0.50, 0.58), .middleTip: jp(0.50, 0.65),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.62, 0.50), .ringDIP: jp(0.62, 0.58), .ringTip: jp(0.62, 0.65),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.70, 0.50), .littleDIP: jp(0.70, 0.58), .littleTip: jp(0.70, 0.65),
        ]
    }

    private static var extendedThumb: [HandJoint: JointPoint] {
        [
            .thumbCMC: jp(0.45, 0.22), .thumbMP: jp(0.38, 0.30), .thumbIP: jp(0.33, 0.38), .thumbTip: jp(0.28, 0.45),
        ]
    }

    /// Curled (fisted) chains, tips pulled within 0.06 of palm center (0.5, 0.35).
    private static var fistedNonThumb: [HandJoint: JointPoint] {
        [
            .indexMCP: jp(0.32, 0.35), .indexPIP: jp(0.47, 0.38), .indexDIP: jp(0.47, 0.355), .indexTip: jp(0.47, 0.33),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.37), .middleDIP: jp(0.50, 0.345), .middleTip: jp(0.50, 0.32),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ]
    }

    /// Thumb tucked to the side, not extended, but far enough from the fisted index tip to read as a fist, not a pinch.
    private static var fistedThumb: [HandJoint: JointPoint] {
        [
            .thumbCMC: jp(0.46, 0.23), .thumbMP: jp(0.40, 0.28), .thumbIP: jp(0.39, 0.26), .thumbTip: jp(0.38, 0.24),
        ]
    }

    // MARK: - Poses

    static func openPalm(t: TimeInterval = 0) -> LandmarkFrame {
        var joints = extendedNonThumb
        joints.merge(extendedThumb) { _, new in new }
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func looseFist(t: TimeInterval = 0) -> LandmarkFrame {
        var joints = fistedNonThumb
        joints.merge(fistedThumb) { _, new in new }
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func indexPoint(t: TimeInterval = 0) -> LandmarkFrame {
        var joints = fistedNonThumb
        joints[.indexMCP] = jp(0.32, 0.35)
        joints[.indexPIP] = jp(0.32, 0.50)
        joints[.indexDIP] = jp(0.32, 0.58)
        joints[.indexTip] = jp(0.32, 0.65)
        joints.merge(fistedThumb) { _, new in new }
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func victory(t: TimeInterval = 0) -> LandmarkFrame {
        var joints: [HandJoint: JointPoint] = [
            .indexMCP: jp(0.34, 0.35), .indexPIP: jp(0.40, 0.50), .indexDIP: jp(0.42, 0.58), .indexTip: jp(0.44, 0.65),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.52, 0.50), .middleDIP: jp(0.54, 0.58), .middleTip: jp(0.56, 0.65),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
            .thumbCMC: jp(0.44, 0.22), .thumbMP: jp(0.38, 0.25), .thumbIP: jp(0.42, 0.29), .thumbTip: jp(0.47, 0.33),
        ]
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func thumbsUp(t: TimeInterval = 0) -> LandmarkFrame {
        var joints: [HandJoint: JointPoint] = [
            .indexMCP: jp(0.44, 0.38), .indexPIP: jp(0.47, 0.41), .indexDIP: jp(0.47, 0.385), .indexTip: jp(0.47, 0.36),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.37), .middleDIP: jp(0.50, 0.345), .middleTip: jp(0.50, 0.32),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
            .thumbCMC: jp(0.5, 0.25), .thumbMP: jp(0.5, 0.32), .thumbIP: jp(0.5, 0.44), .thumbTip: jp(0.5, 0.55),
        ]
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func pinch(_ finger: Finger, closed: Bool, t: TimeInterval = 0) -> LandmarkFrame {
        var joints = extendedNonThumb
        joints.merge(extendedThumb) { _, new in new }
        joints[.wrist] = jp(0.5, 0.2)

        let targetTip: HandJoint
        switch finger {
        case .thumb, .index: targetTip = .indexTip
        case .middle: targetTip = .middleTip
        case .ring: targetTip = .ringTip
        case .little: targetTip = .littleTip
        }

        if closed, let target = joints[targetTip] {
            // Within 0.02 of the target finger's tip.
            joints[.thumbTip] = jp(target.x - 0.005, target.y - 0.005)
        } else {
            // Open-palm spot (already set via extendedThumb above).
            joints[.thumbTip] = jp(0.28, 0.45)
        }
        return frame(t: t, joints)
    }

    /// Index, middle, and little extended; ring curled (thumb extended, out of the way). Exactly
    /// 3 of the 4 non-thumb fingers extended — enough to satisfy `HandSwipeDetector`'s "open-ish"
    /// precondition (≥3 of 4), but deliberately NOT `openPalm` (which needs all 5, including
    /// ring) and not any other `StaticPoseClassifier` pose either (not all 4 non-thumb curled for
    /// `looseFist`; not "ring AND little both curled" for `victory`; not "only index extended"
    /// for `indexPoint`). `classify(_:)` returns nil for this pose. Built for Task 5's armed
    /// swipe integration test: a translated `openPalm` would read as `.openPalm` on every frame
    /// and trip the arbitration engine's 3-consecutive-frame disarm debounce before the swipe's
    /// travel threshold ever crosses — this pose lets `HandSwipeDetector` see genuine "open-ish"
    /// motion while staying invisible to the static classifier and its disarm signal.
    static func threeFingerOpen(t: TimeInterval = 0) -> LandmarkFrame {
        var joints = extendedNonThumb
        joints.merge(extendedThumb) { _, new in new }
        joints.merge(fistedNonThumb.filter { $0.key == .ringMCP || $0.key == .ringPIP || $0.key == .ringDIP || $0.key == .ringTip }) { _, new in new }
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }

    static func typingHand(t: TimeInterval = 0) -> LandmarkFrame {
        var joints: [HandJoint: JointPoint] = [
            .indexMCP: jp(0.40, 0.35), .indexPIP: jp(0.36, 0.40), .indexDIP: jp(0.41, 0.425), .indexTip: jp(0.46, 0.45),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.36, 0.39), .middleDIP: jp(0.43, 0.42), .middleTip: jp(0.50, 0.45),
            .ringMCP: jp(0.60, 0.35), .ringPIP: jp(0.64, 0.40), .ringDIP: jp(0.59, 0.425), .ringTip: jp(0.54, 0.45),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.68, 0.40), .littleDIP: jp(0.63, 0.425), .littleTip: jp(0.58, 0.45),
            .thumbCMC: jp(0.44, 0.28), .thumbMP: jp(0.37, 0.39), .thumbIP: jp(0.40, 0.41), .thumbTip: jp(0.44, 0.43),
        ]
        joints[.wrist] = jp(0.5, 0.2)
        return frame(t: t, joints)
    }
}
