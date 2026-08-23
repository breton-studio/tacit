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
/// **Jitter tolerance**: a single frame that fails the curled/no-pinch precondition (or is
/// missing joints entirely) is forgiven — tracking state is kept and the frame is simply ignored,
/// so one-off detector noise mid-swipe doesn't wipe out real progress. Two consecutive such
/// frames are treated as a genuine posture change and fully reset tracking.
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
    /// Consecutive frames that failed the curled/no-pinch precondition (or had missing joints).
    /// A single one is forgiven as jitter tolerance; see the type's doc comment.
    private var consecutiveBadFrames = 0

    public init(minTravel: Double = 0.35, maxDuration: TimeInterval = 0.5) {
        self.minTravel = minTravel
        self.maxDuration = maxDuration
    }

    /// Feed every frame. Emits `.thumbSwipeForward` / `.thumbSwipeBackward` on the frame where
    /// travel crosses `minTravel`, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard let palmSize = HandGeometry.palmSize(frame), palmSize > 0,
              let wrist = frame.point(.wrist), let thumbTip = frame.point(.thumbTip) else {
            return handleBadFrame()
        }

        let nonThumbCurled: [Finger] = [.index, .middle, .ring, .little]
        let allCurled = nonThumbCurled.allSatisfy {
            HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == false
        }
        let pinchEngaged = (HandGeometry.normalizedDistance(.thumbTip, .indexTip, in: frame) ?? .infinity)
            <= tuning.pinchCloseThreshold

        guard allCurled, !pinchEngaged else {
            // Fingers extended, or a pinch engaged: not a swipe posture. A lone frame like this
            // is forgiven as jitter (see `handleBadFrame`); two in a row is a genuine posture
            // change and fully resets tracking — which also satisfies the "fingers extended"
            // reset condition.
            return handleBadFrame()
        }

        consecutiveBadFrames = 0
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

    /// Counts a frame that failed the curled/no-pinch precondition. The first is forgiven
    /// (tracking state kept, frame otherwise ignored); the second consecutive one triggers a full
    /// reset.
    private mutating func handleBadFrame() -> GestureCandidate? {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= 2 {
            reset()
        }
        return nil
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
        consecutiveBadFrames = 0
    }
}
