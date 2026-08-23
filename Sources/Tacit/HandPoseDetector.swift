import CoreVideo
import Foundation
import TacitCore
import Vision

/// Runs Apple Vision's hand-pose detection on camera frames and maps the results into
/// `LandmarkFrame`s.
///
/// Uses the legacy `VNDetectHumanHandPoseRequest` + `VNImageRequestHandler` API rather than the
/// modern async `DetectHumanHandPoseRequest` / `ImageRequestHandler` API. Both compile fine
/// against this SDK, but they are not equivalent here: the modern API's
/// `HumanHandPoseObservation.JointName` enum has different `rawValue` strings (e.g. `"thumbTip"`)
/// than the legacy `VNHumanHandPoseObservation.JointName` (e.g. `"VNHLKTTIP"`) that
/// `HandJoint.visionName` is built from, per the task brief's explicit instruction to use the
/// legacy constants. Using the legacy API here lets the detector consume that table directly
/// instead of maintaining a second, redundant joint-name mapping — so this is a deliberate
/// choice, not a fallback forced by an SDK fight.
///
/// Thread-agnostic: this class has no `MainActor` (or any other actor) affinity, and holds no
/// mutable state beyond its two `let` configuration values, so it's safe to call `detect` from
/// any queue/thread — including `CaptureEngine`'s dedicated capture queue. `VNImageRequestHandler`
/// is created fresh per call (cheap, per Apple's guidance, and simpler than caching one keyed by
/// pixel buffer format) and `.perform` is synchronous; `detect` is declared `async` to match the
/// required interface and to leave room for off-loading if this ever needs it.
final class HandPoseDetector: Sendable {
    private let maximumHandCount: Int
    private let confidenceFloor: Float

    init(maximumHandCount: Int = 1, confidenceFloor: Float = 0.3) {
        self.maximumHandCount = maximumHandCount
        self.confidenceFloor = confidenceFloor
    }

    /// Detects hand poses in `pixelBuffer` and returns them as `LandmarkFrame`s.
    ///
    /// - Joints reported below `confidenceFloor` are dropped (absent from `LandmarkFrame.joints`).
    /// - `x` is flipped (`x = 1 - x`) to un-mirror the built-in webcam's mirrored feed; `y` is left
    ///   as-is, preserving Vision's normalized, lower-left-origin, y-up convention.
    /// - Vision's `chirality` is mapped straight across to `Handedness` (`.left` → `.left`,
    ///   `.right` → `.right`). Because the image handed to Vision is mirrored, that chirality
    ///   describes the mirrored image, not the un-mirrored one — we report it as-Vision-reports
    ///   rather than trying to correct it, per the task brief.
    /// - Any Vision error results in an empty array.
    func detect(in pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async -> [LandmarkFrame] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHandCount

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        return observations.map { frame(from: $0, timestamp: timestamp) }
    }

    private func frame(from observation: VNHumanHandPoseObservation, timestamp: TimeInterval) -> LandmarkFrame {
        var joints: [HandJoint: JointPoint] = [:]
        for handJoint in HandJoint.allCases {
            let key = VNRecognizedPointKey(rawValue: handJoint.visionName)
            let jointName = VNHumanHandPoseObservation.JointName(rawValue: key)
            guard let point = try? observation.recognizedPoint(jointName),
                  point.confidence >= confidenceFloor
            else { continue }

            joints[handJoint] = JointPoint(
                x: 1 - Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }

        let handedness: Handedness
        switch observation.chirality {
        case .left: handedness = .left
        case .right: handedness = .right
        case .unknown: handedness = .unknown
        @unknown default: handedness = .unknown
        }

        return LandmarkFrame(timestamp: timestamp, joints: joints, handedness: handedness)
    }
}
