import Foundation

/// Detects a whole-hand directional swipe: `.swipeLeft`, `.swipeRight`, `.swipeUp`, `.swipeDown`.
///
/// Tracks the palm center — the mean of the wrist and the four non-thumb MCPs (index, middle,
/// ring, little) — per frame. A swipe emits once, on the frame where, measured from the start of
/// the current tracking window:
///   - net displacement (palm-size-normalized) reaches `minTravel`,
///   - within `maxDuration` of the window's start,
///   - mean speed (net displacement / elapsed time) reaches `minMeanSpeed`,
///   - and the displacement's major axis dominates its minor axis by at least `dominanceRatio`
///     (this also picks the emitted direction: whichever axis dominates, and that axis's sign).
///
/// The hand must read as open-ish — at least 3 of the 4 non-thumb fingers extended
/// (`HandGeometry.isFingerExtended`, default `ClassifierTuning` margin) — on every frame counted
/// toward the window; a fisted or mostly-curled hand never satisfies this, no matter how it moves.
///
/// **Direction convention:** directions are in the *un-mirrored user frame*. Upstream capture
/// already flips x, so by the time frames reach this detector, a user swiping physically to their
/// left shows up as *decreasing* x — that emits `.swipeLeft`. Increasing x emits `.swipeRight`.
/// Coordinates are y-up (`SyntheticHand`'s convention, matching Vision's normalized space),  so
/// increasing y emits `.swipeUp` and decreasing y emits `.swipeDown`.
///
/// **Window mechanics:** rather than buffering every frame, the window is anchored at a single
/// start sample (position + time) and re-anchored at the current frame whenever the elapsed time
/// since that anchor exceeds `maxDuration` — this bounds travel/speed computation to a
/// `maxDuration`-sized rolling window without unbounded history (same technique as
/// `ThumbSwipeDetector`'s `trackingStartX`/`trackingStartTime`).
///
/// **Emit-once, then settle:** after emitting, the detector stops evaluating swipe conditions
/// until it observes 2 consecutive frames whose frame-to-frame palm-center motion is below 0.1
/// palm-units — only then does it re-anchor a fresh window and re-arm.
///
/// **One-frame jitter tolerance:** a single frame that can't compute a palm center (missing
/// wrist/MCP joints) or fails the open-ish requirement is forgiven — tracking state is kept
/// untouched and the frame is simply skipped. Two such frames in a row are treated as a genuine
/// posture/tracking change and fully reset the detector.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct HandSwipeDetector: Sendable {
    private let minTravel: Double
    private let maxDuration: TimeInterval
    private let minMeanSpeed: Double
    private let dominanceRatio: Double
    private let tuning = ClassifierTuning()

    /// Below this normalized (palm-size-divided) frame-to-frame palm-center motion, the hand
    /// counts as "settled" for re-arming purposes.
    private let settleEpsilon: Double = 0.1

    private struct PalmCenter {
        var x: Double
        var y: Double
    }

    private var windowStartCenter: PalmCenter?
    private var windowStartTime: TimeInterval?
    private var previousCenter: PalmCenter?

    /// True immediately after an emission, until 2 consecutive low-motion frames are observed.
    private var awaitingSettle = false
    /// Consecutive low-motion frames observed while `awaitingSettle`.
    private var settleCount = 0
    /// Consecutive frames that failed to compute a palm center or failed the open-ish
    /// requirement. A single one is forgiven; the second consecutive one resets everything.
    private var consecutiveBadFrames = 0

    private static let nonThumbFingers: [Finger] = [.index, .middle, .ring, .little]

    public init(
        minTravel: Double = 1.2,
        maxDuration: TimeInterval = 0.45,
        minMeanSpeed: Double = 4.0,
        dominanceRatio: Double = 2.0
    ) {
        self.minTravel = minTravel
        self.maxDuration = maxDuration
        self.minMeanSpeed = minMeanSpeed
        self.dominanceRatio = dominanceRatio
    }

    /// Feed every frame. Emits `.swipeLeft` / `.swipeRight` / `.swipeUp` / `.swipeDown` on the
    /// frame where travel, speed, and axis dominance all cross their thresholds, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        guard let center = palmCenter(frame), let palmSize = HandGeometry.palmSize(frame), palmSize > 0 else {
            return handleBadFrame()
        }

        if !awaitingSettle {
            let extendedCount = Self.nonThumbFingers.filter {
                HandGeometry.isFingerExtended($0, in: frame, margin: tuning.extensionMargin) == true
            }.count
            guard extendedCount >= 3 else {
                return handleBadFrame()
            }
        }

        consecutiveBadFrames = 0

        if awaitingSettle {
            defer { previousCenter = center }
            guard let previous = previousCenter else { return nil }

            let motion = distance(center, previous) / palmSize
            if motion < settleEpsilon {
                settleCount += 1
                if settleCount >= 2 {
                    awaitingSettle = false
                    settleCount = 0
                    beginTracking(at: center, time: frame.timestamp)
                }
            } else {
                settleCount = 0
            }
            return nil
        }

        previousCenter = center

        guard let startCenter = windowStartCenter, let startTime = windowStartTime else {
            beginTracking(at: center, time: frame.timestamp)
            return nil
        }

        let elapsed = frame.timestamp - startTime
        if elapsed > maxDuration {
            // Stale window: slide it forward instead of letting travel accumulate unbounded over
            // an arbitrarily slow drift.
            beginTracking(at: center, time: frame.timestamp)
            return nil
        }
        guard elapsed > 0 else { return nil }

        let dx = (center.x - startCenter.x) / palmSize
        let dy = (center.y - startCenter.y) / palmSize
        let travel = (dx * dx + dy * dy).squareRoot()
        let meanSpeed = travel / elapsed

        let majorAxis = max(abs(dx), abs(dy))
        let minorAxis = min(abs(dx), abs(dy))

        guard travel >= minTravel, meanSpeed >= minMeanSpeed, majorAxis >= dominanceRatio * minorAxis else {
            return nil
        }

        let gesture: GestureID
        if abs(dx) >= abs(dy) {
            gesture = dx >= 0 ? .swipeRight : .swipeLeft
        } else {
            gesture = dy >= 0 ? .swipeUp : .swipeDown
        }

        awaitingSettle = true
        settleCount = 0
        windowStartCenter = nil
        windowStartTime = nil

        return GestureCandidate(gesture: gesture, confidence: HandGeometry.meanConfidence(frame), timestamp: frame.timestamp)
    }

    /// Counts a frame that failed the palm-center/open-ish precondition. The first is forgiven
    /// (tracking state kept, frame otherwise ignored); the second consecutive one triggers a full
    /// reset.
    private mutating func handleBadFrame() -> GestureCandidate? {
        consecutiveBadFrames += 1
        if consecutiveBadFrames >= 2 {
            reset()
        }
        return nil
    }

    private mutating func beginTracking(at center: PalmCenter, time: TimeInterval) {
        windowStartCenter = center
        windowStartTime = time
        previousCenter = center
    }

    private mutating func reset() {
        windowStartCenter = nil
        windowStartTime = nil
        previousCenter = nil
        awaitingSettle = false
        settleCount = 0
        consecutiveBadFrames = 0
    }

    /// Mean of the wrist and the four non-thumb MCPs. nil if any of those five joints is missing.
    private func palmCenter(_ frame: LandmarkFrame) -> PalmCenter? {
        let joints: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let points = joints.compactMap { frame.point($0) }
        guard points.count == joints.count else { return nil }
        let x = points.reduce(0.0) { $0 + $1.x } / Double(points.count)
        let y = points.reduce(0.0) { $0 + $1.y } / Double(points.count)
        return PalmCenter(x: x, y: y)
    }

    private func distance(_ a: PalmCenter, _ b: PalmCenter) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Detects a fist-to-open transition: a `.looseFist`-classifying frame followed by an
/// `.openPalm`-classifying frame within `maxTransition` seconds of the most recently seen fist
/// frame. Classification is delegated to an internal `StaticPoseClassifier` with default tuning.
///
/// Emits `.fistToOpen` on the qualifying open frame. After emitting, the detector requires the
/// hand to leave `.openPalm` before a new fist phase can start — this prevents a hand that stays
/// open from re-arming a fresh transition on its own. Leaving open straight into a fist starts
/// the next transition immediately, anchored on that frame; leaving into anything else (or
/// nil) returns to idle, awaiting a fresh `.looseFist` frame.
///
/// Frames that classify as neither `.looseFist` nor `.openPalm` while a fist is pending (e.g. an
/// ambiguous mid-transition frame) don't reset tracking outright — they're simply skipped, and
/// the elapsed-time check on a later open frame is still measured against the most recent
/// confirmed fist frame.
///
/// Time comes entirely from `frame.timestamp`; this type never calls `Date()`.
public struct FistToOpenDetector: Sendable {
    private let maxTransition: TimeInterval
    private let classifier = StaticPoseClassifier()

    private enum Phase: Sendable {
        case idle
        case fistSeen(lastAt: TimeInterval)
        case awaitingLeaveOpen
    }

    private var phase: Phase = .idle

    public init(maxTransition: TimeInterval = 0.5) {
        self.maxTransition = maxTransition
    }

    /// Feed every frame. Emits `.fistToOpen` on the frame where a preceding fist transitions to
    /// open within `maxTransition`, or nil otherwise.
    public mutating func ingest(_ frame: LandmarkFrame) -> GestureCandidate? {
        let classification = classifier.classify(frame)?.gesture

        switch phase {
        case .idle:
            if classification == .looseFist {
                phase = .fistSeen(lastAt: frame.timestamp)
            }
            return nil

        case .fistSeen(let lastAt):
            switch classification {
            case .looseFist:
                phase = .fistSeen(lastAt: frame.timestamp)
                return nil
            case .openPalm:
                let elapsed = frame.timestamp - lastAt
                guard elapsed <= maxTransition else {
                    phase = .idle
                    return nil
                }
                phase = .awaitingLeaveOpen
                return GestureCandidate(
                    gesture: .fistToOpen,
                    confidence: HandGeometry.meanConfidence(frame),
                    timestamp: frame.timestamp
                )
            default:
                return nil
            }

        case .awaitingLeaveOpen:
            switch classification {
            case .openPalm:
                return nil // still open: hasn't left yet
            case .looseFist:
                // Leaving open straight into a fist starts the next transition immediately,
                // anchored on this frame, rather than losing it by routing through idle.
                phase = .fistSeen(lastAt: frame.timestamp)
                return nil
            default:
                phase = .idle
                return nil
            }
        }
    }
}
