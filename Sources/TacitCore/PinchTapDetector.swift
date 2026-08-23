import Foundation

/// Detects a quick pinch-and-release ("tap") between the thumb and one of the four fingertips.
///
/// A tap is: thumb-to-target distance dips below `tuning.pinchCloseThreshold` (close), then rises
/// back above `tuning.pinchOpenThreshold` (release, with hysteresis against jitter in between) —
/// all within `maxTapDuration` seconds. The target finger is whichever fingertip is closest to the
/// thumb at the moment the pinch closes; it stays locked to that finger until release.
///
/// A pinch held longer than `maxTapDuration` before releasing emits nothing on release — that's a
/// hold/drag gesture (M3's `.pinchDrag`), not a tap, and is intentionally out of scope here.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`, so replay against
/// recorded fixtures is deterministic.
public struct PinchTapDetector: Sendable {
    private let tuning: ClassifierTuning
    private let maxTapDuration: TimeInterval

    private enum Phase: Sendable {
        case idle
        case closed(target: Finger, closedAt: TimeInterval)
    }

    private var phase: Phase = .idle

    public init(tuning: ClassifierTuning = ClassifierTuning(), maxTapDuration: TimeInterval = 0.6) {
        self.tuning = tuning
        self.maxTapDuration = maxTapDuration
    }

    /// Feed every frame. Emits `.thumbIndexTap` / `.thumbMiddleTap` / `.thumbRingPinkyTap` on the
    /// release frame of a qualifying tap, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        switch phase {
        case .idle:
            guard let (target, distance) = closestTarget(in: frame), distance < tuning.pinchCloseThreshold else {
                return nil
            }
            phase = .closed(target: target, closedAt: frame.timestamp)
            return nil

        case .closed(let target, let closedAt):
            guard let distance = HandGeometry.normalizedDistance(.thumbTip, tipJoint(for: target), in: frame) else {
                // Target joint dropped out of tracking; abandon this pinch attempt defensively.
                phase = .idle
                return nil
            }

            // Still pinched, or in the open/close hysteresis dead zone: keep waiting for release.
            guard distance > tuning.pinchOpenThreshold else { return nil }

            phase = .idle
            let elapsed = frame.timestamp - closedAt
            guard elapsed <= maxTapDuration else { return nil }

            return GestureCandidate(
                gesture: gestureID(for: target),
                confidence: HandGeometry.meanConfidence(frame),
                timestamp: frame.timestamp
            )
        }
    }

    /// The fingertip closest to the thumb this frame, and its normalized distance. nil if no
    /// fingertip distance can be computed (e.g. missing joints).
    private func closestTarget(in frame: LandmarkFrame) -> (Finger, Double)? {
        let candidates: [Finger] = [.index, .middle, .ring, .little]
        return candidates
            .compactMap { finger -> (Finger, Double)? in
                guard let distance = HandGeometry.normalizedDistance(.thumbTip, tipJoint(for: finger), in: frame) else {
                    return nil
                }
                return (finger, distance)
            }
            .min { $0.1 < $1.1 }
    }

    private func tipJoint(for finger: Finger) -> HandJoint {
        switch finger {
        case .thumb: return .thumbTip
        case .index: return .indexTip
        case .middle: return .middleTip
        case .ring: return .ringTip
        case .little: return .littleTip
        }
    }

    /// Ring and little share one gesture per the ergonomics report.
    private func gestureID(for finger: Finger) -> GestureID {
        switch finger {
        case .thumb, .index: return .thumbIndexTap
        case .middle: return .thumbMiddleTap
        case .ring, .little: return .thumbRingPinkyTap
        }
    }
}
