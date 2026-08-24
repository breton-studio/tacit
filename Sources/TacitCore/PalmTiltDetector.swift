import Foundation

/// Tunable thresholds for `PalmTiltDetector`. All angles are degrees.
public struct PalmTiltTuning: Sendable {
    /// `|roll|` must reach this before a tilt starts emitting candidates.
    public var enterDegrees: Double = 25
    /// `|roll|` at which candidate confidence caps out at 1.0 (the linear ramp's top end).
    public var fullConfidenceDegrees: Double = 40
    /// `|roll|` must drop below this before the detector will emit for a new excursion.
    public var rearmDegrees: Double = 10

    public init() {}
}

/// Detects an open-palm tilt — the hand held open, leaning left or right — emitting
/// `.palmTiltLeft` / `.palmTiltRight`. This is a pose-*plus*-orientation gesture: the pose half
/// (open palm) is delegated to an internal `StaticPoseClassifier` so the finger-extension checks
/// live in exactly one place; the orientation half is this type's own job.
///
/// **Roll measurement:** on any frame the internal classifier reads as `.openPalm`, roll is the
/// signed angle between the wrist→middleMCP vector and screen-up, `atan2(dx, dy)` in degrees
/// (`dx`/`dy` = middleMCP − wrist), over the same un-mirrored, y-up coordinate space
/// `HandSwipeDetector`/`WristRotateDetector` document — upstream capture already flips x, so a
/// user's own left shows up as *decreasing* x by the time frames reach this detector.
///
/// **Direction convention:** fingers leaning toward the user's left (roll negative — the
/// wrist→middleMCP vector swung toward decreasing x) emit `.palmTiltLeft`; leaning toward the
/// user's right (roll positive) emit `.palmTiltRight`. One tilt is one emission burst (see below),
/// not a continuous stream — "one tilt = one app."
///
/// **Confidence:** ramps linearly from 0.6 at `tuning.enterDegrees` to 1.0 at
/// `tuning.fullConfidenceDegrees` (clamped to 1.0 beyond it), so a full-tilt candidate clears
/// `ArbitrationTuning`'s clutch-off floor (`enterConfidence 0.6 + clutchOffConfidenceBoost 0.15 =
/// 0.75`) well before the ramp tops out.
///
/// **Emission contract (one fire per excursion):** unlike the single-frame swipe detectors, this
/// type emits a candidate on EVERY qualifying frame while tilted past `enterDegrees` — it doesn't
/// know when (or whether) `ArbitrationEngine` actually fires an event from any given candidate, so
/// it can't self-debounce the way `ThumbSwipeDetector`/`HandSwipeDetector` do (those detectors
/// control their own single emission frame; this one's "frame" is however long the user holds the
/// tilt). To still guarantee at most one *excursion's* worth of firing rather than a candidate on
/// every frame of a held tilt, the detector stops emitting once it has emitted for
/// `ArbitrationTuning().debounceFrames + 1` consecutive frames in the current direction — one more
/// than the arbitration engine's own debounce window needs to fire, so the fire is guaranteed to
/// have already happened before this cutoff, and the extra frame is slack against off-by-one
/// timing rather than a second deliberate signal. Emission only resumes after `|roll|` drops below
/// `tuning.rearmDegrees` — i.e. the hand returns most of the way to upright — which also resets the
/// per-direction emission count. Between `rearmDegrees` and `enterDegrees` (the dead zone) the
/// detector holds whatever state it already had: it neither re-arms nor advances the emission
/// count, so a tilt that eases off without fully returning upright can't restart a fresh burst.
///
/// **Jitter tolerance:** a single frame that isn't classified `.openPalm` (or is missing the
/// wrist/middleMCP joints) is forgiven — tracking state is kept and the frame is simply skipped.
/// Two such frames in a row are treated as a genuine posture change and fully reset the detector —
/// exactly the `HandSwipeDetector`/`ThumbSwipeDetector`/`WristRotateDetector` precedent.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct PalmTiltDetector: Sendable {
    private let tuning: PalmTiltTuning
    private let classifier = StaticPoseClassifier()
    /// One more than `ArbitrationTuning().debounceFrames` — see the type doc comment's "Emission
    /// contract" section.
    private let maxConsecutiveEmissions: Int

    /// The direction currently accumulating consecutive emissions, or nil between excursions.
    private var currentDirection: GestureID?
    /// Consecutive frames emitted for `currentDirection` since it was last (re-)armed.
    private var consecutiveEmissions: Int = 0
    /// Consecutive frames that failed the `.openPalm`/joint precondition. A single one is
    /// forgiven; the second consecutive one triggers a full reset.
    private var consecutiveBadFrames: Int = 0

    public init(tuning: PalmTiltTuning = PalmTiltTuning(), maxConsecutiveEmissions: Int = ArbitrationTuning().debounceFrames + 1) {
        self.tuning = tuning
        self.maxConsecutiveEmissions = maxConsecutiveEmissions
    }

    /// Feed every frame. Emits `.palmTiltLeft` / `.palmTiltRight` on each qualifying frame of an
    /// excursion, up to `maxConsecutiveEmissions` consecutive frames, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard classifier.classify(frame)?.gesture == .openPalm,
              let wrist = frame.point(.wrist), let middleMCP = frame.point(.middleMCP) else {
            return handleBadFrame()
        }
        consecutiveBadFrames = 0

        let dx = middleMCP.x - wrist.x
        let dy = middleMCP.y - wrist.y
        guard dx != 0 || dy != 0 else { return nil }
        let rollDegrees = atan2(dx, dy) * 180 / Double.pi
        let magnitude = abs(rollDegrees)

        if magnitude < tuning.rearmDegrees {
            currentDirection = nil
            consecutiveEmissions = 0
            return nil
        }

        guard magnitude >= tuning.enterDegrees else {
            // Dead zone between rearmDegrees and enterDegrees: hold state, neither re-arming nor
            // advancing the emission count.
            return nil
        }

        let direction: GestureID = rollDegrees > 0 ? .palmTiltRight : .palmTiltLeft
        if direction != currentDirection {
            currentDirection = direction
            consecutiveEmissions = 0
        }

        guard consecutiveEmissions < maxConsecutiveEmissions else { return nil }
        consecutiveEmissions += 1

        let range = tuning.fullConfidenceDegrees - tuning.enterDegrees
        let progress = range > 0 ? min(max((magnitude - tuning.enterDegrees) / range, 0), 1) : 1
        let confidence = 0.6 + 0.4 * progress

        return GestureCandidate(gesture: direction, confidence: confidence, timestamp: frame.timestamp)
    }

    /// Counts a frame that failed the `.openPalm`/joint precondition. The first is forgiven
    /// (tracking state kept, frame otherwise ignored); the second consecutive one triggers a full
    /// reset.
    private mutating func handleBadFrame() -> GestureCandidate? {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= 2 {
            reset()
        }
        return nil
    }

    private mutating func reset() {
        currentDirection = nil
        consecutiveEmissions = 0
        consecutiveBadFrames = 0
    }
}
