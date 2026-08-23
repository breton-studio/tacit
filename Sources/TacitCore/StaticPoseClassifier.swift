import Foundation

/// Tunable thresholds for `StaticPoseClassifier`. All distances are palm-size-normalized
/// (see `HandGeometry.normalizedDistance`).
public struct ClassifierTuning: Sendable {
    /// Margin passed to `HandGeometry.isFingerExtended`.
    public var extensionMargin: Double = 1.15
    /// Below this normalized thumb-tip distance, fingers read as pinched together.
    public var pinchCloseThreshold: Double = 0.35
    /// Above this normalized thumb-tip distance, a pinch is considered released (hysteresis).
    public var pinchOpenThreshold: Double = 0.60
    /// Frames with mean joint confidence below this never classify.
    public var minMeanConfidence: Double = 0.5
    /// Minimum normalized index-tip↔middle-tip spread for a victory sign.
    public var victoryMinTipSpread: Double = 0.45

    public init() {}
}

/// Classifies a single `LandmarkFrame` into one static-pose `GestureCandidate`, or nil.
///
/// M1 recognizes `looseFist` and `openPalm` only. Task 12 extends `classify(_:)` with more
/// poses by appending matcher functions to the `matchers` list below — keep the dispatch
/// itself untouched so rule ordering stays legible.
public struct StaticPoseClassifier: Sendable {
    private let tuning: ClassifierTuning

    public init(tuning: ClassifierTuning = ClassifierTuning()) {
        self.tuning = tuning
    }

    /// Best static-pose candidate for this frame, or nil. Confidence = meanConfidence of the frame.
    public func classify(_ frame: LandmarkFrame) -> GestureCandidate? {
        let confidence = HandGeometry.meanConfidence(frame)
        guard confidence >= tuning.minMeanConfidence else { return nil }

        // Ordered rule evaluation: first matching pose wins.
        // Priority: victory > indexPoint > thumbsUp > looseFist > openPalm.
        // (thumbsUp must precede looseFist: a thumbsUp frame also satisfies looseFist's
        // "four fingers curled + thumb away from index" test, so ordering disambiguates it.)
        let matchers: [(LandmarkFrame) -> GestureID?] = [
            matchVictory,
            matchIndexPoint,
            matchThumbsUp,
            matchLooseFist,
            matchOpenPalm,
        ]

        guard let gesture = matchers.lazy.compactMap({ $0(frame) }).first else {
            return nil
        }

        return GestureCandidate(gesture: gesture, confidence: confidence, timestamp: frame.timestamp)
    }

    // MARK: - Pose rules

    private func matchOpenPalm(_ frame: LandmarkFrame) -> GestureID? {
        let allExtended = Finger.allCases.allSatisfy {
            HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == true
        }
        return allExtended ? .openPalm : nil
    }

    private func matchLooseFist(_ frame: LandmarkFrame) -> GestureID? {
        let nonThumbCurled: [Finger] = [.index, .middle, .ring, .little]
        let allCurled = nonThumbCurled.allSatisfy {
            HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == false
        }
        guard allCurled else { return nil }

        guard let thumbIndexDistance = HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame),
              thumbIndexDistance > tuning.pinchCloseThreshold else {
            return nil
        }

        return .looseFist
    }

    /// Index extended; middle, ring, little not. Thumb state is ignored.
    private func matchIndexPoint(_ frame: LandmarkFrame) -> GestureID? {
        guard isExtended(.index, frame) else { return nil }
        let othersCurled: [Finger] = [.middle, .ring, .little]
        guard othersCurled.allSatisfy({ !isExtended($0, frame) }) else { return nil }
        return .indexPoint
    }

    /// Index and middle extended, ring and little not, tips spread apart. Thumb state is ignored.
    private func matchVictory(_ frame: LandmarkFrame) -> GestureID? {
        guard isExtended(.index, frame), isExtended(.middle, frame) else { return nil }
        let othersCurled: [Finger] = [.ring, .little]
        guard othersCurled.allSatisfy({ !isExtended($0, frame) }) else { return nil }
        guard let tipSpread = HandGeometry.normalizedDistance(.indexTip, .middleTip, in: frame),
              tipSpread >= tuning.victoryMinTipSpread else {
            return nil
        }
        return .victory
    }

    /// Thumb extended, index/middle/ring/little not, thumb tip above (screen-up from) the index MCP.
    private func matchThumbsUp(_ frame: LandmarkFrame) -> GestureID? {
        let nonThumbCurled: [Finger] = [.index, .middle, .ring, .little]
        guard nonThumbCurled.allSatisfy({ !isExtended($0, frame) }) else { return nil }
        guard isExtended(.thumb, frame) else { return nil }
        guard let thumbTip = frame.point(.thumbTip), let indexMCP = frame.point(.indexMCP),
              thumbTip.y > indexMCP.y else {
            return nil
        }
        return .thumbsUp
    }

    /// Convenience wrapper over `HandGeometry.isFingerExtended` using this classifier's tuning margin.
    private func isExtended(_ finger: Finger, _ frame: LandmarkFrame) -> Bool {
        HandGeometry.isFingerExtended(finger, in: frame, margin: tuning.extensionMargin) == true
    }
}
