import Foundation

/// Detects a partial-arc wrist rotation performed while the hand is fisted (index/middle/ring/
/// little all curled, per `ClassifierTuning.extensionMargin` — thumb ignored), emitting a
/// `.wristRotateCW` / `.wristRotateCCW` tick every `tickArcDegrees` of accumulated rotation.
///
/// **Angle measurement:** each frame's orientation is the angle of the wrist→middleMCP vector,
/// `atan2(middleMCP.y - wrist.y, middleMCP.x - wrist.x)` in degrees, over the un-mirrored, y-up
/// coordinate space the rest of TacitCore uses (see `HandSwipeDetector`'s direction convention
/// doc). Frame-to-frame deltas are wrapped to `(-180, 180]` before accumulating, so a rotation
/// that crosses the ±180° seam (e.g. 175° → -175°) still contributes a small +10° step rather
/// than a spurious ~350° jump.
///
/// **Sign convention:** in this un-mirrored, y-up space, a *decreasing* atan2 angle is clockwise
/// as the user sees it (picture the vector sweeping from pointing up-and-left (135°), through up
/// (90°), toward up-and-right (45°) — that reads as a clockwise turn of the wrist from the user's
/// viewpoint, and the angle is falling). So a negative accumulated delta is `.wristRotateCW`; a
/// positive one is `.wristRotateCCW`.
///
/// **Accumulation and ticking:** `netArcDegrees` is the signed sum of every wrapped delta since
/// engagement began (i.e. position relative to the fisted pose the hand started in, not a
/// sliding window — unlike the swipe detectors, a rotation can usefully run well past any single
/// window). A tick fires every time `floor(|netArcDegrees| / tickArcDegrees)` increases; because
/// that quantity shrinks back toward zero as the hand unwinds and only grows again once it
/// re-passes the same magnitude in the new direction, reversing direction mid-rotation costs the
/// full trip back through zero before a tick can fire the other way — no cross-direction credit,
/// with no separate reset bookkeeping required.
///
/// **Partial-arc clamp (Rempel ergonomics):** once `|netArcDegrees|` reaches `maxArcDegrees`,
/// ticking locks out — even if the hand keeps turning further past the clamp — until the hand
/// unwinds back to `maxArcDegrees - tickArcDegrees` (one tick-arc back toward the fisted starting
/// orientation). This mirrors the ergonomics report's guidance to keep wrist rotation to a
/// comfortable partial arc rather than a full pronation/supination sweep.
///
/// **Jitter tolerance:** a single frame that fails the fisted precondition (or is missing the
/// wrist/middleMCP joints) is forgiven — tracking state is kept and the frame is simply ignored.
/// Two consecutive such frames are treated as a genuine disengage (hand opened, or tracking lost)
/// and fully reset the detector, exactly as `ThumbSwipeDetector`/`HandSwipeDetector` do.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct WristRotateDetector: Sendable {
    private let tickArcDegrees: Double
    private let maxArcDegrees: Double
    private let tuning = ClassifierTuning()

    private static let nonThumbFingers: [Finger] = [.index, .middle, .ring, .little]

    /// The orientation angle (degrees) as of the last tracked frame, or nil while disengaged.
    private var previousAngleDegrees: Double?
    /// Signed accumulated arc (degrees) since engagement began; negative = wound clockwise,
    /// positive = wound counter-clockwise.
    private var netArcDegrees: Double = 0
    /// `floor(|netArcDegrees| / tickArcDegrees)` as of the last frame evaluated (frozen while
    /// `clamped`), used to detect the crossing that fires the next tick.
    private var tickLevel: Int = 0
    /// True once `|netArcDegrees|` has reached `maxArcDegrees` in the current span; blocks further
    /// ticks until the hand unwinds by at least one `tickArcDegrees`.
    private var clamped = false
    /// Consecutive frames that failed the fisted precondition or had missing joints. A single one
    /// is forgiven; the second consecutive one triggers a full reset.
    private var consecutiveBadFrames = 0

    public init(tickArcDegrees: Double = 20, maxArcDegrees: Double = 70) {
        self.tickArcDegrees = tickArcDegrees
        self.maxArcDegrees = maxArcDegrees
    }

    /// Feed every frame. Emits `.wristRotateCW` / `.wristRotateCCW` on the frame where accumulated
    /// rotation crosses another `tickArcDegrees` multiple (subject to the partial-arc clamp), or
    /// nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard isFisted(frame), let angle = wristMiddleAngleDegrees(frame) else {
            return handleBadFrame()
        }
        consecutiveBadFrames = 0

        guard let previousAngle = previousAngleDegrees else {
            beginTracking(angle: angle)
            return nil
        }

        netArcDegrees += wrappedDelta(from: previousAngle, to: angle)
        previousAngleDegrees = angle

        return evaluateTick(frame: frame)
    }

    // MARK: - Engagement

    private func isFisted(_ frame: LandmarkFrame) -> Bool {
        Self.nonThumbFingers.allSatisfy {
            HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == false
        }
    }

    private func wristMiddleAngleDegrees(_ frame: LandmarkFrame) -> Double? {
        guard let wrist = frame.point(.wrist), let middleMCP = frame.point(.middleMCP) else { return nil }
        let dx = middleMCP.x - wrist.x
        let dy = middleMCP.y - wrist.y
        guard dx != 0 || dy != 0 else { return nil }
        return atan2(dy, dx) * 180 / Double.pi
    }

    /// `current - previous`, wrapped into `(-180, 180]` so a crossing of the ±180° seam reads as
    /// the small step it physically is, rather than a ~360°-magnitude jump.
    private func wrappedDelta(from previous: Double, to current: Double) -> Double {
        var delta = current - previous
        while delta > 180 { delta -= 360 }
        while delta <= -180 { delta += 360 }
        return delta
    }

    // MARK: - Tick / clamp evaluation

    private mutating func evaluateTick(frame: LandmarkFrame) -> GestureCandidate? {
        let maxTicks = Int(maxArcDegrees / tickArcDegrees)
        let magnitude = abs(netArcDegrees)

        if clamped {
            if magnitude <= maxArcDegrees - tickArcDegrees {
                clamped = false
                tickLevel = Int(magnitude / tickArcDegrees)
            }
            return nil
        }

        let level = min(Int(magnitude / tickArcDegrees), maxTicks)
        defer {
            tickLevel = level
            if magnitude >= maxArcDegrees { clamped = true }
        }

        guard level > tickLevel else { return nil }

        let gesture: GestureID = netArcDegrees < 0 ? .wristRotateCW : .wristRotateCCW
        return GestureCandidate(gesture: gesture, confidence: HandGeometry.meanConfidence(frame), timestamp: frame.timestamp)
    }

    // MARK: - Tracking lifecycle

    private mutating func beginTracking(angle: Double) {
        previousAngleDegrees = angle
        netArcDegrees = 0
        tickLevel = 0
        clamped = false
    }

    /// Counts a frame that failed the fisted precondition or had missing joints. The first is
    /// forgiven (tracking state kept, frame otherwise ignored); the second consecutive one
    /// triggers a full reset.
    private mutating func handleBadFrame() -> GestureCandidate? {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= 2 {
            reset()
        }
        return nil
    }

    private mutating func reset() {
        previousAngleDegrees = nil
        netArcDegrees = 0
        tickLevel = 0
        clamped = false
        consecutiveBadFrames = 0
    }
}

/// Detects a two-finger vertical scroll performed with exactly index and middle extended and ring
/// and little curled (thumb ignored; the fingertips are allowed to stay together — this is
/// deliberately *not* the victory sign's tip-spread requirement), emitting a
/// `.twoFingerScrollUp` / `.twoFingerScrollDown` tick every `tickTravel` palm-units of
/// accumulated vertical travel.
///
/// **Tracking point:** the midpoint of the index and middle fingertips. Its y-displacement,
/// normalized by `HandGeometry.palmSize`, accumulates into a signed running total since
/// engagement began — the same "position since engagement start, not a sliding window"
/// accumulation `WristRotateDetector` uses, for the same reason (a scroll can run well past any
/// single travel window).
///
/// **Direction convention:** coordinates are y-up (matching `HandSwipeDetector`'s convention), so
/// increasing y (accumulated total positive) emits `.twoFingerScrollUp`; decreasing y
/// (accumulated total negative) emits `.twoFingerScrollDown`.
///
/// **Ticking and direction flips:** a tick fires every time
/// `floor(|accumulated travel| / tickTravel)` increases. Because that quantity shrinks back
/// toward zero as the hand reverses and only grows again once it re-passes the same magnitude in
/// the new direction, a direction flip mid-scroll costs the full trip back through zero before a
/// tick can fire the other way — no cross-direction credit, no phantom ticks on the way back
/// through neutral.
///
/// **Jitter tolerance:** a single frame that fails the exact index+middle-extended /
/// ring+little-curled precondition (or is missing joints) is forgiven — tracking state is kept
/// and the frame is simply ignored. Two consecutive such frames are treated as a genuine
/// disengage and fully reset the detector.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct TwoFingerScrollDetector: Sendable {
    private let tickTravel: Double
    private let tuning = ClassifierTuning()

    /// y-coordinate of the index+middle tip midpoint as of the last tracked frame, or nil while
    /// disengaged.
    private var previousMidpointY: Double?
    /// Signed accumulated vertical travel (palm-units) since engagement began; positive = up,
    /// negative = down.
    private var netTravel: Double = 0
    /// `floor(|netTravel| / tickTravel)` as of the last frame evaluated, used to detect the
    /// crossing that fires the next tick.
    private var tickLevel: Int = 0
    /// Consecutive frames that failed the engagement precondition or had missing joints. A
    /// single one is forgiven; the second consecutive one triggers a full reset.
    private var consecutiveBadFrames = 0

    public init(tickTravel: Double = 0.35) {
        self.tickTravel = tickTravel
    }

    /// Feed every frame. Emits `.twoFingerScrollUp` / `.twoFingerScrollDown` on the frame where
    /// accumulated vertical travel crosses another `tickTravel` multiple, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard isEngaged(frame), let palmSize = HandGeometry.palmSize(frame), palmSize > 0,
              let y = midpointY(frame) else {
            return handleBadFrame()
        }
        consecutiveBadFrames = 0

        guard let previousY = previousMidpointY else {
            beginTracking(y: y)
            return nil
        }

        netTravel += (y - previousY) / palmSize
        previousMidpointY = y

        return evaluateTick(frame: frame)
    }

    // MARK: - Engagement

    private func isEngaged(_ frame: LandmarkFrame) -> Bool {
        HandGeometry.isFingerExtended(.index, in: frame, margin: tuning.extensionMargin) == true &&
            HandGeometry.isFingerExtended(.middle, in: frame, margin: tuning.extensionMargin) == true &&
            HandGeometry.isFingerExtended(.ring, in: frame, margin: tuning.extensionMargin) == false &&
            HandGeometry.isFingerExtended(.little, in: frame, margin: tuning.extensionMargin) == false
    }

    private func midpointY(_ frame: LandmarkFrame) -> Double? {
        guard let indexTip = frame.point(.indexTip), let middleTip = frame.point(.middleTip) else { return nil }
        return (indexTip.y + middleTip.y) / 2
    }

    // MARK: - Tick evaluation

    private mutating func evaluateTick(frame: LandmarkFrame) -> GestureCandidate? {
        let magnitude = abs(netTravel)
        let level = Int(magnitude / tickTravel)
        defer { tickLevel = level }

        guard level > tickLevel else { return nil }

        let gesture: GestureID = netTravel > 0 ? .twoFingerScrollUp : .twoFingerScrollDown
        return GestureCandidate(gesture: gesture, confidence: HandGeometry.meanConfidence(frame), timestamp: frame.timestamp)
    }

    // MARK: - Tracking lifecycle

    private mutating func beginTracking(y: Double) {
        previousMidpointY = y
        netTravel = 0
        tickLevel = 0
    }

    /// Counts a frame that failed the engagement precondition or had missing joints. The first is
    /// forgiven (tracking state kept, frame otherwise ignored); the second consecutive one
    /// triggers a full reset.
    private mutating func handleBadFrame() -> GestureCandidate? {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= 2 {
            reset()
        }
        return nil
    }

    private mutating func reset() {
        previousMidpointY = nil
        netTravel = 0
        tickLevel = 0
        consecutiveBadFrames = 0
    }
}
