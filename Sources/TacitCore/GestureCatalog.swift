import Foundation

/// How often a gesture is meant to be used, per the ergonomics research's frequency tiers
/// (`docs/research/LowFatigue-Economic-Hand-Gestures.md`, §C "Frequency tiers" and the Top 20 list's
/// three buckets). Workhorses are the desk-resting, high-frequency core; occasional gestures trade a
/// little more motion/fatigue for lower false-positive risk; deliberate gestures are rare, free-air,
/// and unmistakable.
public enum GestureTier: String, Codable, CaseIterable, Sendable {
    case workhorse, occasional, deliberate
}

/// The shape of the gesture's detection problem: a single-frame pose, a motion/state-machine
/// gesture, or a two-handed gesture.
public enum GestureKind: String, Codable, Sendable {
    case staticPose, dynamic, twoHand
}

/// One row of the specimen-book catalog: the editorial and ergonomic metadata behind a
/// `GestureID`, sourced from the ergonomics report's Summary table and Design principles.
public struct CatalogEntry: Sendable {
    public var id: GestureID
    public var displayName: String
    public var tier: GestureTier
    public var kind: GestureKind
    /// Fatigue/RSI characterization from the report's Summary table, e.g. "Low fatigue",
    /// "Moderate fatigue", "High fatigue" — always phrased as "<level> fatigue" so the value reads
    /// unambiguously even detached from the field name.
    public var comfort: String
    /// False-positive risk from the report's Summary table, e.g. "Low", "Medium", "Very Low".
    public var falsePositiveRisk: String
    /// A quiet, factual one-line note derived from the report's rationale for this gesture.
    public var editorial: String
    /// True only for `looseFist` (clutch/activation) and `openPalm` (disarm) — the two gestures the
    /// system reserves for itself and never exposes as user-bindable.
    public var isReserved: Bool
    /// The specimen book's line-art for this gesture (spec §5): a hand-tuned 21-joint frame that
    /// reads unambiguously as this gesture — the pose itself for a static gesture, or its
    /// most-legible keyframe for a dynamic one. Always derived from `CannedFrames.frame(for: id)`
    /// so `id` and `cannedFrame` can never drift out of sync with each other.
    public var cannedFrame: LandmarkFrame
    /// Task 7 (Try-It session): one line of concrete, plain-verb coaching on what the detector
    /// actually needs, shown when a Try-It session times out without registering this gesture —
    /// sourced from the ergonomics research (`docs/research/LowFatigue-Economic-Hand-Gestures.md`),
    /// not generic encouragement. Phrased as a respectful correction (e.g. "brush the fingertip,
    /// don't squeeze"), never an exclamation.
    public var hint: String

    /// Task 7 fix round (Medium finding): whether ANY code path in `TacitCore` — production or
    /// preview — can ever produce this gesture as a `GestureCandidate`. `false` for exactly
    /// `GestureCatalog.undetectedGestures` (see that set's doc comment for which three and why).
    /// A Try-It session for a non-detector-backed gesture would always time out no matter how well
    /// the user performs it, which reads as user error rather than a missing feature — callers
    /// (`CardDetailView`) use this to show honest "still in the works" copy instead of a "Try It"
    /// button that can never succeed.
    public var isDetectorBacked: Bool {
        !GestureCatalog.undetectedGestures.contains(id)
    }

    public init(
        id: GestureID,
        displayName: String,
        tier: GestureTier,
        kind: GestureKind,
        comfort: String,
        falsePositiveRisk: String,
        editorial: String,
        isReserved: Bool = false,
        hint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.kind = kind
        self.comfort = comfort
        self.falsePositiveRisk = falsePositiveRisk
        self.editorial = editorial
        self.isReserved = isReserved
        self.cannedFrame = CannedFrames.frame(for: id)
        self.hint = hint
    }
}

/// The editorial data behind the specimen-book UI: every `GestureID`, described with the ergonomic
/// metadata (comfort, false-positive risk, tier) and the quiet prose that explains why it belongs
/// where it does. Sourced entirely from `docs/research/LowFatigue-Economic-Hand-Gestures.md`.
public enum GestureCatalog {
    /// All 25 gestures, in spec §5 order: the eight static workhorses followed by the thumb-swipe
    /// pair (report gesture #9, split into two `GestureID`s), then occasional 10–17 with the
    /// wrist-rotate and two-finger-scroll gestures each split into a directional pair (the same
    /// precedent as the #9 thumb-swipe split), plus the 2026-08-24 palm-tilt pair (the app-switch
    /// job's replacement for the hand swipes, which stay in the catalog but ship disabled — see
    /// `MappingStore` defaults revision 7), then the three deliberate free-air gestures.
    public static let entries: [CatalogEntry] = [
        // MARK: Workhorses (report gestures 1–8, plus the #9 thumb-swipe pair)
        CatalogEntry(
            id: .thumbIndexTap,
            displayName: "Thumb–Index Tap",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Medium",
            editorial: "The lowest-excursion discrete action available — a light touch and release, "
                + "not a squeeze, keeps the thumb joint out of harm's way.",
            isReserved: false,
            hint: "A light touch — brush the fingertip, don't squeeze."
        ),
        CatalogEntry(
            id: .thumbMiddleTap,
            displayName: "Thumb–Middle Tap",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Medium",
            editorial: "A second, distinct thumb channel; the middle finger is the next most "
                + "independently controllable digit after the index.",
            isReserved: false,
            hint: "A light touch with the middle finger — brush the fingertip, don't squeeze."
        ),
        CatalogEntry(
            id: .indexPoint,
            displayName: "Index Point",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low–Medium",
            editorial: "Point to speak: hold to dictate, release to stop.",
            isReserved: false,
            hint: "Point with a relaxed hand and hold the pose — a quick jab won't register."
        ),
        CatalogEntry(
            id: .victory,
            displayName: "Victory",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "Two separated fingers are easy for the camera to tell apart, but the spread "
                + "costs more comfort than it appears to — keep it brief, not held.",
            isReserved: false,
            hint: "Spread the index and middle fingers into a clear V — a half-open V can read as a fist."
        ),
        CatalogEntry(
            id: .thumbsUp,
            displayName: "Thumbs-Up",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "A comfortable, highly separable pose; its main risk is firing during an "
                + "ordinary conversational thumbs-up, not fatigue.",
            isReserved: false,
            hint: "Extend the thumb clearly away from the fist — a tucked thumb can look closed."
        ),
        CatalogEntry(
            id: .looseFist,
            displayName: "Loose Fist",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "Reserved as the system's clutch: a loose fist rates as comfortable and is "
                + "detected almost perfectly, making it the natural gesture to arm the system "
                + "before anything else fires.",
            isReserved: true,
            hint: "Curl the fingers into a relaxed fist — loose reads better than clenched."
        ),
        CatalogEntry(
            id: .openPalm,
            displayName: "Open Palm",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "Reserved as the system's disarm: maximum landmark visibility for the "
                + "camera, with fingers relaxed rather than splayed to stay comfortable.",
            isReserved: true,
            hint: "Open the hand fully, fingers relaxed, palm toward the camera."
        ),
        CatalogEntry(
            id: .thumbRingPinkyTap,
            displayName: "Thumb–Ring/Pinky Tap",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Medium",
            editorial: "Anatomically it's a thumb tap, so it sits with the other workhorses — but "
                + "the ring finger is tendon-coupled to the middle finger and the pinky is weak, "
                + "and the research rates this one for occasional rather than high-frequency use.",
            isReserved: false,
            hint: "Bring the thumb to the ring or pinky finger with a light touch — give the "
                + "tendon-linked fingers a beat to separate."
        ),
        CatalogEntry(
            id: .thumbSwipeForward,
            displayName: "Thumb Swipe Forward",
            tier: .workhorse,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "A small thumb swipe along the index finger — the core low-fatigue "
                + "microgesture, distinguishable from a resting hand by its motion alone.",
            isReserved: false,
            hint: "One quick, deliberate flick of the thumb along the index finger — speed "
                + "matters more than distance."
        ),
        CatalogEntry(
            id: .thumbSwipeBackward,
            displayName: "Thumb Swipe Backward",
            tier: .workhorse,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "The mirror of the forward swipe; paired opposite gestures like this are "
                + "easier to learn and to recall under pressure.",
            isReserved: false,
            hint: "One quick, deliberate flick of the thumb back along the index finger — speed "
                + "matters more than distance."
        ),

        // MARK: Occasional (report gestures 10–17)
        CatalogEntry(
            id: .swipeLeft,
            displayName: "Swipe Left",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low–Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "An unambiguous directional flick; it costs more motion than a static pose "
                + "but is rarely triggered by accident.",
            isReserved: false,
            hint: "Swipe left with your whole hand, wrist leading — one clean flick, not a drift."
        ),
        CatalogEntry(
            id: .swipeRight,
            displayName: "Swipe Right",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low–Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "Switch apps with a flick to the right.",
            isReserved: false,
            hint: "Swipe right with your whole hand, wrist leading — one clean flick, not a drift."
        ),
        CatalogEntry(
            id: .swipeUp,
            displayName: "Swipe Up",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "Swipe up into the text field.",
            isReserved: false,
            hint: "Swipe upward with your whole hand, wrist leading — one clean flick, not a drift."
        ),
        CatalogEntry(
            id: .swipeDown,
            displayName: "Swipe Down",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "Mirrors swipe up, with the same moderate effort and the same "
                + "occasional-use budget.",
            isReserved: false,
            hint: "Swipe downward with your whole hand, wrist leading — one clean flick, not a drift."
        ),
        CatalogEntry(
            id: .fistToOpen,
            displayName: "Fist to Open",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Very Low",
            editorial: "Chaining two robust static states into one gesture makes this the most "
                + "false-positive-resistant dynamic gesture in the catalog.",
            isReserved: false,
            hint: "Start from a clear fist, then bloom the hand fully open — hold each end for a beat."
        ),
        CatalogEntry(
            id: .pinchDrag,
            displayName: "Pinch Drag",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "A held pinch gives a clean start and stop for continuous control, provided "
                + "the pinch stays a light touch rather than a squeeze.",
            isReserved: false,
            hint: "Pinch thumb and index together, then move while holding the pinch — release "
                + "fully to end the drag."
        ),
        CatalogEntry(
            id: .wristRotateCW,
            displayName: "Wrist Rotate Clockwise",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "A rotary metaphor for continuous values, kept to a partial arc rather than a "
                + "full pronation. Turns fire a tick per motion increment while you rotate — bind "
                + "something you want repeated.",
            isReserved: false,
            hint: "Turn the wrist clockwise in a small arc — keep the turn under a quarter turn."
        ),
        CatalogEntry(
            id: .wristRotateCCW,
            displayName: "Wrist Rotate Counter-Clockwise",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "The mirror of the clockwise turn, same partial-arc limit. Ticks fire the "
                + "other direction while you rotate — bind something you want repeated.",
            isReserved: false,
            hint: "Turn the wrist counter-clockwise in a small arc — keep the turn under a quarter turn."
        ),
        CatalogEntry(
            id: .twoFingerScrollUp,
            displayName: "Two-Finger Scroll Up",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "A familiar scroll metaphor with well-separated landmarks. Ticks fire "
                + "repeatedly while you scroll — bind something you want repeated.",
            isReserved: false,
            hint: "Move two extended fingers upward together, steady and slow — pace, not "
                + "distance, drives the scroll."
        ),
        CatalogEntry(
            id: .twoFingerScrollDown,
            displayName: "Two-Finger Scroll Down",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "Mirrors the upward scroll, ticking the other direction at the same "
                + "repeating cadence — bind something you want repeated.",
            isReserved: false,
            hint: "Move two extended fingers downward together, steady and slow — pace, not "
                + "distance, drives the scroll."
        ),

        CatalogEntry(
            id: .palmTiltLeft,
            displayName: "Palm Tilt Left",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "A quarter-turn of an already-open hand — like turning a page. Replaces the "
                + "whole-hand swipe for app-switching, which was going undetected for enough users "
                + "to retire it.",
            isReserved: false,
            hint: "Show your open palm, then lean the fingers to the left about a quarter turn — "
                + "come back upright before the next one."
        ),
        CatalogEntry(
            id: .palmTiltRight,
            displayName: "Palm Tilt Right",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low",
            editorial: "The mirror of the left tilt — the same quarter-turn, the other way.",
            isReserved: false,
            hint: "Show your open palm, then lean the fingers to the right about a quarter turn — "
                + "come back upright before the next one."
        ),

        // MARK: Deliberate (report gestures 18–20)
        CatalogEntry(
            id: .palmPush,
            displayName: "Palm Push",
            tier: .deliberate,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "A deliberate push toward the camera; depth is coarse on a single lens, so "
                + "this is best used as one big, infrequent confirmation.",
            isReserved: false,
            hint: "Push the open palm toward the camera in one clear motion, then pull back."
        ),
        CatalogEntry(
            id: .wave,
            displayName: "Wave",
            tier: .deliberate,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Medium",
            editorial: "Highly visible and socially legible, which cuts both ways — reserved for "
                + "rare use so it doesn't fire in the middle of a conversation.",
            isReserved: false,
            hint: "Wave the open hand side to side at least twice, keeping the motion visible and "
                + "unhurried."
        ),
        CatalogEntry(
            id: .twoHandFrame,
            displayName: "Two-Hand Frame",
            tier: .deliberate,
            kind: .twoHand,
            comfort: "High fatigue",
            falsePositiveRisk: "Very Low",
            editorial: "Two hands together are nearly impossible to trigger by accident, which is "
                + "exactly why this is reserved for a single rare, powerful action.",
            isReserved: false,
            hint: "Bring both hands together to frame the shot and hold for a beat — small, "
                + "controlled motion counts more than speed."
        ),
    ]

    /// Task 7 fix round (Medium finding): the exact `GestureID`s with NO detector anywhere in
    /// `TacitCore` — no code path, production or preview, can ever produce them as a
    /// `GestureCandidate` (verified against `StaticPoseClassifier` and every `PipelineCore`
    /// detector, production and preview alike). Detectors for these three are parked to the
    /// post-M4 backlog by plan ruling:
    ///  - `.palmPush` — needs a depth/scale-toward-camera detector; none exists.
    ///  - `.wave` — needs an oscillation (side-to-side reversal) detector; none exists.
    ///  - `.twoHandFrame` — needs a two-hand detector; `HandPoseDetector` only tracks one hand.
    ///
    /// This is the single source of truth `CatalogEntry.isDetectorBacked`/`detectorBackedGestures`
    /// below are derived from, so landing a detector for any of these three forces a conscious
    /// edit here (and to the test pinning this exact set) instead of silently going stale.
    public static let undetectedGestures: Set<GestureID> = [.palmPush, .wave, .twoHandFrame]

    /// The complement of `undetectedGestures`: every `GestureID` at least one detector (production
    /// or preview) can actually produce. Equivalent to, and kept in lockstep with,
    /// `CatalogEntry.isDetectorBacked` — this is the set-valued form for callers that want to test
    /// membership without looking an entry up first.
    public static var detectorBackedGestures: Set<GestureID> {
        Set(GestureID.allCases).subtracting(undetectedGestures)
    }

    /// Section editorial headers (spec §5): one quiet, factual line per tier.
    public static let tierEditorial: [GestureTier: String] = [
        .workhorse: "Built for a resting arm: brief, near-zero-force poses meant to fire dozens of "
            + "times an hour without fatigue.",
        .occasional: "Trades a little more motion for a lot less false-positive risk — for things "
            + "you do a few times an hour, not a few times a minute.",
        .deliberate: "Free-air and unmistakable: rare, high-visibility gestures reserved for actions "
            + "you want to be nearly impossible to trigger by accident.",
    ]

    private static let entriesByID: [GestureID: CatalogEntry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) }
    )

    /// The catalog entry for `id`. Every `GestureID` case has exactly one entry, so this always
    /// succeeds.
    public static func entry(for id: GestureID) -> CatalogEntry {
        guard let entry = entriesByID[id] else {
            preconditionFailure("GestureCatalog is missing an entry for \(id) — every GestureID case must have one.")
        }
        return entry
    }

    /// All entries belonging to `tier`, in catalog order.
    public static func entries(in tier: GestureTier) -> [CatalogEntry] {
        entries.filter { $0.tier == tier }
    }
}
