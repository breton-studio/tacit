import Foundation

/// Detects a held-and-translated thumb-index pinch: `.pinchDrag`.
///
/// A pinch closes when the normalized thumb-index distance drops below
/// `tuning.pinchCloseThreshold`. While it stays closed (or in the open/close hysteresis dead
/// zone — released only once the distance clears `tuning.pinchOpenThreshold`, mirroring
/// `PinchTapDetector`'s hysteresis), the detector watches two conditions against the pinch point
/// (the thumb-index tip midpoint) as it was when the pinch closed:
///   - held for at least `minHold` seconds, and
///   - translated at least 0.4 palm-units from where it closed.
///
/// `.pinchDrag` emits once, on the first frame where both conditions are simultaneously true, and
/// then latches silent for the rest of the engagement — it does not re-fire on every subsequent
/// frame the pinch keeps moving. Release (or losing the tracked joints) resets everything, ready
/// for a fresh engagement.
///
/// **Overlap with `PinchTapDetector` is real and intentional, not a bug**: a pinch held between
/// `minHold` (0.25 s by default) and `PinchTapDetector`'s `maxTapDuration` (0.6 s) that also
/// happens to translate ≥ 0.4 palm-units *and* release before 0.6 s elapses will be claimed by
/// both detectors — `PinchTapDetector` fires `.thumbIndexTap` on release, `PinchDragDetector`
/// already fired `.pinchDrag` mid-hold once translation crossed the line. Disambiguation between
/// the two is left to whichever consumer wires up both detectors (arbitration policy), not to
/// either detector individually; each one is only responsible for its own honest read of what the
/// hand did.
///
/// **v1 scope**: recognition and preview only. `.pinchDrag` stays unbindable to actions — true
/// continuous 2D drag control is out of scope until a later milestone. Callers must not wire this
/// detector's output into the production dispatch path, only a preview consumer.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct PinchDragDetector: Sendable {
    private let tuning: ClassifierTuning
    private let minHold: TimeInterval

    /// Minimum normalized (palm-size-divided) displacement of the pinch point from where it
    /// closed, required alongside `minHold` before `.pinchDrag` can fire.
    private let minTranslation: Double = 0.4

    private struct PinchPoint {
        var x: Double
        var y: Double
    }

    private enum Phase: Sendable {
        case idle
        case closed(startPoint: PinchPoint, closedAt: TimeInterval, emitted: Bool)
    }

    private var phase: Phase = .idle

    public init(tuning: ClassifierTuning = ClassifierTuning(), minHold: TimeInterval = 0.25) {
        self.tuning = tuning
        self.minHold = minHold
    }

    /// Feed every frame. Emits `.pinchDrag` once per engagement, on the frame where both the hold
    /// and translation conditions are first simultaneously satisfied; nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard let pinchDistance = HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame),
              let point = pinchPoint(frame), let palmSize = HandGeometry.palmSize(frame), palmSize > 0 else {
            // Missing joints: defensively drop out of any pinch-in-progress, same as
            // `PinchTapDetector` does when its target joint disappears mid-pinch.
            phase = .idle
            return nil
        }

        switch phase {
        case .idle:
            guard pinchDistance < tuning.pinchCloseThreshold else { return nil }
            phase = .closed(startPoint: point, closedAt: frame.timestamp, emitted: false)
            return nil

        case .closed(let startPoint, let closedAt, let emitted):
            guard pinchDistance <= tuning.pinchOpenThreshold else {
                // Cleared the hysteresis band: released. Reset regardless of whether this
                // engagement ever emitted.
                phase = .idle
                return nil
            }

            guard !emitted else {
                // Already emitted once this engagement; stay latched silent until release.
                return nil
            }

            let elapsed = frame.timestamp - closedAt
            guard elapsed >= minHold else { return nil }

            let travel = displacement(point, startPoint) / palmSize
            guard travel >= minTranslation else { return nil }

            phase = .closed(startPoint: startPoint, closedAt: closedAt, emitted: true)
            return GestureCandidate(gesture: .pinchDrag, confidence: HandGeometry.meanConfidence(frame), timestamp: frame.timestamp)
        }
    }

    private func pinchPoint(_ frame: LandmarkFrame) -> PinchPoint? {
        guard let thumbTip = frame.point(.thumbTip), let indexTip = frame.point(.indexTip) else { return nil }
        return PinchPoint(x: (thumbTip.x + indexTip.x) / 2, y: (thumbTip.y + indexTip.y) / 2)
    }

    private func displacement(_ a: PinchPoint, _ b: PinchPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
