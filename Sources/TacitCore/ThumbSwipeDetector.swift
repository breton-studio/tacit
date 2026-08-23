import Foundation

/// Detects a lateral thumb swipe performed while the hand is fisted (index/middle/ring/little all
/// curled, per `ClassifierTuning.extensionMargin`) and no pinch is engaged (thumb-to-index
/// distance stays above `ClassifierTuning.pinchCloseThreshold`).
///
/// **Direction convention** (handedness-agnostic, documented rather than derived from
/// `LandmarkFrame.handedness`): direction is relative to the wrist→thumb vector at the start of
/// the tracked motion, not absolute screen x. If the thumb starts to one side of the wrist along
/// x, movement that *increases* that separation is `.thumbSwipeForward` ("away from the wrist");
/// movement that *decreases* it is `.thumbSwipeBackward` ("toward the wrist"). This reads
/// correctly for a fisted hand held either right-side-up or upside-down, and for either hand,
/// without consulting `handedness`.
///
/// Travel is thumbTip x-displacement from the start of the current tracking window, normalized by
/// palm size (`HandGeometry.palmSize`). Reaching `minTravel` within `maxDuration` of that window's
/// start emits once; the detector then requires an explicit reset — the thumb going stationary
/// (small frame-to-frame x movement) or the fingers extending — before it will emit again.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct ThumbSwipeDetector: Sendable {
    private let minTravel: Double
    private let maxDuration: TimeInterval
    private let tuning = ClassifierTuning()

    /// Below this normalized frame-to-frame x movement, the thumb counts as "stationary" for
    /// reset purposes.
    private let stationaryEpsilon: Double = 0.02

    private var trackingStartX: Double?
    private var trackingStartTime: TimeInterval?
    /// Sign of (thumbTip.x − wrist.x) at the start of the current tracking window: +1 if the
    /// thumb started to the right of the wrist, −1 if to the left (0 treated as +1, an
    /// unreachable tie in practice).
    private var wristSignAtStart: Double = 1
    /// Previous frame's thumbTip.x, for stationary-reset detection while awaiting reset.
    private var previousX: Double?
    /// True immediately after an emission, until an explicit reset (stationary thumb or extended
    /// fingers) is observed.
    private var awaitingReset = false

    public init(minTravel: Double = 0.35, maxDuration: TimeInterval = 0.5) {
        self.minTravel = minTravel
        self.maxDuration = maxDuration
    }

    /// Feed every frame. Emits `.thumbSwipeForward` / `.thumbSwipeBackward` on the frame where
    /// travel crosses `minTravel`, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard let palmSize = HandGeometry.palmSize(frame), palmSize > 0,
              let wrist = frame.point(.wrist), let thumbTip = frame.point(.thumbTip) else {
            reset()
            return nil
        }

        let nonThumbCurled: [Finger] = [.index, .middle, .ring, .little]
        let allCurled = nonThumbCurled.allSatisfy {
            HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == false
        }
        let pinchEngaged = (HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame) ?? .infinity)
            <= tuning.pinchCloseThreshold

        guard allCurled, !pinchEngaged else {
            // Fingers extended, or a pinch engaged: not a swipe posture. This also satisfies the
            // "fingers extended" reset condition, so drop all tracking state.
            reset()
            return nil
        }

        let currentX = thumbTip.x

        guard let startX = trackingStartX, let startTime = trackingStartTime else {
            beginTracking(at: currentX, wristX: wrist.x, time: frame.timestamp)
            return nil
        }

        if awaitingReset, let prevX = previousX {
            let frameDelta = abs(currentX - prevX) / palmSize
            if frameDelta < stationaryEpsilon {
                // Stationary reset condition satisfied: start a fresh window right here.
                awaitingReset = false
                beginTracking(at: currentX, wristX: wrist.x, time: frame.timestamp)
                return nil
            }
        }
        previousX = currentX

        let elapsed = frame.timestamp - startTime
        if elapsed > maxDuration {
            // This window is stale; slide it forward instead of letting travel accumulate
            // unbounded over an arbitrarily slow drift.
            beginTracking(at: currentX, wristX: wrist.x, time: frame.timestamp)
            return nil
        }

        let travel = (currentX - startX) / palmSize
        guard !awaitingReset, abs(travel) >= minTravel else { return nil }

        let directionSign = travel * wristSignAtStart
        guard directionSign != 0 else { return nil }

        let gesture: GestureID = directionSign > 0 ? .thumbSwipeForward : .thumbSwipeBackward
        awaitingReset = true
        beginTracking(at: currentX, wristX: wrist.x, time: frame.timestamp)
        return GestureCandidate(gesture: gesture, confidence: HandGeometry.meanConfidence(frame), timestamp: frame.timestamp)
    }

    private mutating func beginTracking(at x: Double, wristX: Double, time: TimeInterval) {
        trackingStartX = x
        trackingStartTime = time
        wristSignAtStart = (x - wristX) >= 0 ? 1 : -1
        previousX = x
    }

    private mutating func reset() {
        trackingStartX = nil
        trackingStartTime = nil
        wristSignAtStart = 1
        previousX = nil
        awaitingReset = false
    }
}
