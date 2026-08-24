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

    public init(
        id: GestureID,
        displayName: String,
        tier: GestureTier,
        kind: GestureKind,
        comfort: String,
        falsePositiveRisk: String,
        editorial: String,
        isReserved: Bool = false
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
    }
}

/// The editorial data behind the specimen-book UI: every `GestureID`, described with the ergonomic
/// metadata (comfort, false-positive risk, tier) and the quiet prose that explains why it belongs
/// where it does. Sourced entirely from `docs/research/LowFatigue-Economic-Hand-Gestures.md`.
public enum GestureCatalog {
    /// All 23 gestures, in spec §5 order: the eight static workhorses followed by the thumb-swipe
    /// pair (report gesture #9, split into two `GestureID`s), then occasional 10–17 with the
    /// wrist-rotate and two-finger-scroll gestures each split into a directional pair (the same
    /// precedent as the #9 thumb-swipe split), then the three deliberate free-air gestures.
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
            isReserved: false
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
            isReserved: false
        ),
        CatalogEntry(
            id: .indexPoint,
            displayName: "Index Point",
            tier: .workhorse,
            kind: .staticPose,
            comfort: "Low fatigue",
            falsePositiveRisk: "Low–Medium",
            editorial: "Point to speak: hold to dictate, release to stop.",
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: true
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
            isReserved: true
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
        ),
        CatalogEntry(
            id: .swipeRight,
            displayName: "Swipe Right",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Low–Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "Switch apps with a flick to the right.",
            isReserved: false
        ),
        CatalogEntry(
            id: .swipeUp,
            displayName: "Swipe Up",
            tier: .occasional,
            kind: .dynamic,
            comfort: "Moderate fatigue",
            falsePositiveRisk: "Low",
            editorial: "Swipe up into the text field.",
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
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
            isReserved: false
        ),
    ]

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
