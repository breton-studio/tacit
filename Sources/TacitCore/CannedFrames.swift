import Foundation

/// Hand-tuned, production canned `LandmarkFrame`s — one per catalog gesture, each the single
/// frame that reads most legibly as that gesture in still line-art: for a static pose, the pose
/// itself; for a dynamic gesture, its most-legible keyframe (per Task 17's brief — e.g.
/// `swipeLeft` is an open hand mid-frame with an implied lean, `pinchDrag` is pinch-closed,
/// `twoHandFrame` renders the single hand's half of the two-hand pose).
///
/// This is the single source of truth for every canned (non-live) constellation render in the
/// app: `GestureCatalog`'s `CatalogEntry.cannedFrame`, the menu bar glyph's fist, and the HUD's
/// no-live-frame fallback all point here — nobody else should hand-roll a display `LandmarkFrame`.
///
/// Geometry follows the same construction style as `Tests/TacitCoreTests/SyntheticHand.swift`
/// (wrist at (0.5, 0.2), palm size ~0.15, confidence 0.9, normalized 0...1, origin lower-left,
/// y up) — but these are production data living in `TacitCore`, not test fixtures, per the brief.
public enum CannedFrames {

    // MARK: - Point/frame construction

    private static func jp(_ x: Double, _ y: Double) -> JointPoint {
        JointPoint(x: x, y: y, confidence: 0.9)
    }

    private static func assemble(
        _ nonThumb: [HandJoint: JointPoint],
        _ thumb: [HandJoint: JointPoint],
        wrist: JointPoint = JointPoint(x: 0.5, y: 0.2, confidence: 0.9)
    ) -> LandmarkFrame {
        var joints = nonThumb
        joints.merge(thumb) { _, new in new }
        joints[.wrist] = wrist
        return LandmarkFrame(timestamp: 0, joints: joints, handedness: .right)
    }

    /// A thumb chain bent from its base toward `target` — the CMC/MP root stays fixed (where the
    /// thumb actually hinges from the palm), the IP joint sits 60% of the way from MP to the
    /// target (a plausible bent-knuckle midpoint), and the tip lands exactly on `target`. Reused
    /// by every tap/pinch/swipe gesture, which differ only in where the thumb tip lands.
    private static func bentThumb(toward target: JointPoint) -> [HandJoint: JointPoint] {
        let cmc = jp(0.45, 0.22)
        let mp = jp(0.40, 0.30)
        let ip = jp(mp.x + (target.x - mp.x) * 0.6, mp.y + (target.y - mp.y) * 0.6)
        return [.thumbCMC: cmc, .thumbMP: mp, .thumbIP: ip, .thumbTip: target]
    }

    /// Rotates and/or scales `joints` about `pivot` (in practice, always the wrist) — the shared
    /// mechanism behind every "leaning"/"rotated"/"reaching" keyframe (swipes, wrist-rotate, palm
    /// push, wave). A rotation changes the joints' relative shape (unlike a plain translation), so
    /// it reads as a genuinely different pose under `ConstellationRenderer`'s `fitToJoints` mode.
    private static func transformed(
        _ joints: [HandJoint: JointPoint],
        pivot: (x: Double, y: Double),
        rotationDegrees: Double,
        scale: Double = 1.0
    ) -> [HandJoint: JointPoint] {
        let theta = rotationDegrees * Double.pi / 180
        let cosT = cos(theta), sinT = sin(theta)
        var result: [HandJoint: JointPoint] = [:]
        for (joint, point) in joints {
            let dx = (point.x - pivot.x) * scale
            let dy = (point.y - pivot.y) * scale
            let x = pivot.x + dx * cosT - dy * sinT
            let y = pivot.y + dx * sinT + dy * cosT
            result[joint] = jp(x, y)
        }
        return result
    }

    /// Linear interpolation between two same-shaped joint dictionaries (excluding the wrist, which
    /// callers add separately) — used for `fistToOpen`'s mid-transition keyframe. Joints missing
    /// from either side are simply omitted from the result.
    private static func interpolated(
        _ a: [HandJoint: JointPoint], _ b: [HandJoint: JointPoint], t: Double
    ) -> [HandJoint: JointPoint] {
        var result: [HandJoint: JointPoint] = [:]
        for joint in HandJoint.allCases where joint != .wrist {
            guard let pa = a[joint], let pb = b[joint] else { continue }
            result[joint] = jp(pa.x + (pb.x - pa.x) * t, pa.y + (pb.y - pa.y) * t)
        }
        return result
    }

    private static let wristPivot = (x: 0.5, y: 0.2)

    /// Rotates every joint of `frame` about its own wrist by `degrees`, keeping the wrist itself
    /// fixed — the palm-tilt canned frames are derived from `openPalm` this way rather than
    /// hand-tuned from scratch, so they can never drift out of sync with the base open-palm
    /// geometry. Uses the same rotation convention as `transformed`/`PalmTiltDetector`/
    /// `Tests/TacitCoreTests/SyntheticHand.swift`'s `rotate` helper (standard math, y-up: positive
    /// `degrees` is counter-clockwise, which swings the wrist→middleMCP vector toward decreasing x
    /// — the user's left, per `PalmTiltDetector`'s roll convention — so `degrees: 30` yields
    /// `.palmTiltLeft`'s frame and `degrees: -30` yields `.palmTiltRight`'s).
    private static func rotatedAboutWrist(_ frame: LandmarkFrame, degrees: Double) -> LandmarkFrame {
        let wrist = frame.point(.wrist) ?? JointPoint(x: 0.5, y: 0.2, confidence: 0.9)
        var nonWristJoints = frame.joints
        nonWristJoints.removeValue(forKey: .wrist)
        var rotatedJoints = transformed(nonWristJoints, pivot: (x: wrist.x, y: wrist.y), rotationDegrees: degrees)
        rotatedJoints[.wrist] = wrist
        return LandmarkFrame(timestamp: frame.timestamp, joints: rotatedJoints, handedness: frame.handedness)
    }

    // MARK: - Shared finger chains (mirrors SyntheticHand's construction style)

    private static var extendedNonThumb: [HandJoint: JointPoint] {
        [
            .indexMCP: jp(0.32, 0.35), .indexPIP: jp(0.32, 0.50), .indexDIP: jp(0.32, 0.58), .indexTip: jp(0.32, 0.65),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.50), .middleDIP: jp(0.50, 0.58), .middleTip: jp(0.50, 0.65),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.62, 0.50), .ringDIP: jp(0.62, 0.58), .ringTip: jp(0.62, 0.65),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.70, 0.50), .littleDIP: jp(0.70, 0.58), .littleTip: jp(0.70, 0.65),
        ]
    }

    private static var extendedThumb: [HandJoint: JointPoint] {
        [.thumbCMC: jp(0.45, 0.22), .thumbMP: jp(0.38, 0.30), .thumbIP: jp(0.33, 0.38), .thumbTip: jp(0.28, 0.45)]
    }

    private static var openPalmJoints: [HandJoint: JointPoint] {
        extendedNonThumb.merging(extendedThumb) { _, new in new }
    }

    private static var fistedNonThumb: [HandJoint: JointPoint] {
        [
            .indexMCP: jp(0.32, 0.35), .indexPIP: jp(0.47, 0.38), .indexDIP: jp(0.47, 0.355), .indexTip: jp(0.47, 0.33),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.37), .middleDIP: jp(0.50, 0.345), .middleTip: jp(0.50, 0.32),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ]
    }

    private static var fistedThumb: [HandJoint: JointPoint] {
        [.thumbCMC: jp(0.46, 0.23), .thumbMP: jp(0.40, 0.28), .thumbIP: jp(0.39, 0.26), .thumbTip: jp(0.38, 0.24)]
    }

    private static var fistedJoints: [HandJoint: JointPoint] {
        fistedNonThumb.merging(fistedThumb) { _, new in new }
    }

    /// Index extended straight up, the other three fingers curled — the base shape for
    /// `indexPoint` and the thumb-swipe pair (a swipe travels along this extended index finger).
    private static var indexExtendedChain: [HandJoint: JointPoint] {
        var joints = fistedNonThumb
        joints[.indexMCP] = jp(0.32, 0.35)
        joints[.indexPIP] = jp(0.32, 0.50)
        joints[.indexDIP] = jp(0.32, 0.58)
        joints[.indexTip] = jp(0.32, 0.65)
        return joints
    }

    // MARK: - Workhorses (report gestures 1–8, plus the #9 thumb-swipe pair)

    /// Thumb tip lands on the index tip while the other fingers stay loosely open — a light touch,
    /// not a squeeze (per the catalog's own editorial for this gesture).
    public static let thumbIndexTap: LandmarkFrame =
        assemble(extendedNonThumb, bentThumb(toward: jp(0.315, 0.645)))

    /// The same light-touch shape, retargeted to the middle finger.
    public static let thumbMiddleTap: LandmarkFrame =
        assemble(extendedNonThumb, bentThumb(toward: jp(0.495, 0.645)))

    /// A loose point: index extended, everything else (including the thumb) curled in.
    public static let indexPoint: LandmarkFrame =
        assemble(indexExtendedChain, fistedThumb)

    /// Index and middle forking apart into a real "V" — separation *increases* row by row from
    /// the MCP knuckle row (~0.16) out to the tips (~0.19, comfortably over the 0.18 floor a real
    /// V needs) rather than narrowing back toward the center line. Ring/little curled, thumb
    /// tucked, per the classic victory sign.
    public static let victory: LandmarkFrame = assemble(
        [
            .indexMCP: jp(0.34, 0.35), .indexPIP: jp(0.335, 0.50), .indexDIP: jp(0.33, 0.58), .indexTip: jp(0.325, 0.65),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.505, 0.50), .middleDIP: jp(0.51, 0.58), .middleTip: jp(0.515, 0.65),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ],
        [.thumbCMC: jp(0.44, 0.22), .thumbMP: jp(0.38, 0.25), .thumbIP: jp(0.42, 0.29), .thumbTip: jp(0.47, 0.33)]
    )

    /// Fingers curled, thumb extended straight up — thumbs-up.
    public static let thumbsUp: LandmarkFrame = assemble(
        [
            .indexMCP: jp(0.44, 0.38), .indexPIP: jp(0.47, 0.41), .indexDIP: jp(0.47, 0.385), .indexTip: jp(0.47, 0.36),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.37), .middleDIP: jp(0.50, 0.345), .middleTip: jp(0.50, 0.32),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ],
        [.thumbCMC: jp(0.5, 0.25), .thumbMP: jp(0.5, 0.32), .thumbIP: jp(0.5, 0.44), .thumbTip: jp(0.5, 0.55)]
    )

    /// The system's clutch gesture. Hand-tuned so the joints' own bounding box is close to square
    /// (~0.22 × 0.19) rather than wide-and-flat: under `fitToJoints` at small render sizes (the
    /// menu bar glyph, 18×18) a near-square bbox reads as a compact fist blob instead of a splayed
    /// hand. Wrist low-center; MCP knuckle row fanning up from it; each finger's PIP/DIP/tip curled
    /// back toward a point just above the knuckle row (how Vision actually reports a fist — folded
    /// fingers read as ABOVE the MCP row, not below it); thumb tucked to the side, clear of the
    /// curled tips. (The menu bar glyph itself now renders a Lucide `hand-fist` icon rather than
    /// this constellation frame — see `Sources/Tacit/LucideGlyphs.swift` — but the HUD, Library,
    /// and popover body still draw this frame as line-art.)
    public static let looseFist: LandmarkFrame = {
        let joints: [HandJoint: JointPoint] = [
            .wrist: jp(0.50, 0.16),

            .thumbCMC: jp(0.44, 0.19), .thumbMP: jp(0.40, 0.22), .thumbIP: jp(0.39, 0.20), .thumbTip: jp(0.38, 0.18),

            .indexMCP: jp(0.42, 0.30), .indexPIP: jp(0.49, 0.33), .indexDIP: jp(0.49, 0.315), .indexTip: jp(0.49, 0.30),
            .middleMCP: jp(0.48, 0.30), .middlePIP: jp(0.505, 0.35), .middleDIP: jp(0.505, 0.335), .middleTip: jp(0.505, 0.32),
            .ringMCP: jp(0.54, 0.30), .ringPIP: jp(0.52, 0.33), .ringDIP: jp(0.52, 0.315), .ringTip: jp(0.52, 0.30),
            .littleMCP: jp(0.60, 0.30), .littlePIP: jp(0.535, 0.31), .littleDIP: jp(0.535, 0.295), .littleTip: jp(0.535, 0.28),
        ]
        return LandmarkFrame(timestamp: 0, joints: joints, handedness: .right)
    }()

    /// The system's disarm gesture: maximum landmark visibility, fingers relaxed and open.
    public static let openPalm: LandmarkFrame = assemble(extendedNonThumb, extendedThumb)

    /// Anatomically a thumb tap, retargeted to the ring finger (the report's "ring/pinky" pairing).
    public static let thumbRingPinkyTap: LandmarkFrame =
        assemble(extendedNonThumb, bentThumb(toward: jp(0.615, 0.645)))

    /// Mid-swipe: thumb advanced up along the extended index finger, toward the fingertip.
    public static let thumbSwipeForward: LandmarkFrame =
        assemble(indexExtendedChain, bentThumb(toward: jp(0.34, 0.55)))

    /// The mirror keyframe: thumb retreated down toward the index finger's base.
    public static let thumbSwipeBackward: LandmarkFrame =
        assemble(indexExtendedChain, bentThumb(toward: jp(0.34, 0.38)))

    // MARK: - Occasional (report gestures 10–17)

    /// An open hand leaning left — the implied-motion keyframe example from the brief.
    public static let swipeLeft: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: -22), [:])

    /// The mirrored lean.
    public static let swipeRight: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: 22), [:])

    /// An open hand tilted and reaching further from the wrist — "up."
    public static let swipeUp: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: 8, scale: 1.12), [:])

    /// An open hand tilted the other way and drawn in closer to the wrist — "down."
    public static let swipeDown: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: -8, scale: 0.85), [:])

    /// The most legible keyframe for a fist-to-open release: exactly halfway between the two
    /// static end states, so both the curl and the opening are still visible at once.
    public static let fistToOpen: LandmarkFrame =
        assemble(interpolated(fistedJoints, openPalmJoints, t: 0.5), [:])

    /// Pinch-closed (the clutch of the drag), leaning slightly forward to imply the hand is
    /// mid-translation rather than resting.
    public static let pinchDrag: LandmarkFrame = assemble(
        transformed(
            extendedNonThumb.merging(bentThumb(toward: jp(0.315, 0.645))) { _, new in new },
            pivot: wristPivot, rotationDegrees: 12
        ),
        [:]
    )

    /// A large rotation of the open-palm pose about the wrist, clockwise — literally the gesture
    /// itself.
    public static let wristRotateCW: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: 35), [:])

    /// The mirrored rotation — same pose, the opposite way about the wrist.
    public static let wristRotateCCW: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: -35), [:])

    /// Index and middle held close together (not spread, unlike victory), ring/little curled,
    /// thumb tucked — the scroll gesture's two-finger contact patch, shared by both scroll
    /// directions.
    private static var twoFingerScrollBase: [HandJoint: JointPoint] {
        [
            .indexMCP: jp(0.40, 0.35), .indexPIP: jp(0.40, 0.50), .indexDIP: jp(0.40, 0.58), .indexTip: jp(0.40, 0.65),
            .middleMCP: jp(0.48, 0.35), .middlePIP: jp(0.48, 0.50), .middleDIP: jp(0.48, 0.58), .middleTip: jp(0.48, 0.65),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ]
    }

    /// Offsets the two contact-patch fingertips (only) by `dy`, implying the tips have traveled
    /// up or down from the base contact pose — the up/down keyframe distinction for the scroll
    /// pair.
    private static func withScrollTipOffset(_ dy: Double) -> [HandJoint: JointPoint] {
        var joints = twoFingerScrollBase
        if let indexTip = joints[.indexTip] { joints[.indexTip] = jp(indexTip.x, indexTip.y + dy) }
        if let middleTip = joints[.middleTip] { joints[.middleTip] = jp(middleTip.x, middleTip.y + dy) }
        return joints
    }

    /// The scroll contact patch with both fingertips advanced upward — "up."
    public static let twoFingerScrollUp: LandmarkFrame =
        assemble(withScrollTipOffset(0.05), fistedThumb)

    /// The mirror: both fingertips drawn back downward — "down."
    public static let twoFingerScrollDown: LandmarkFrame =
        assemble(withScrollTipOffset(-0.05), fistedThumb)

    /// The open-palm pose leaned toward the user's left — `openPalm` rotated 30° about the wrist.
    /// See `rotatedAboutWrist`'s doc comment for why +30° (not −30°) yields the left tilt.
    public static let palmTiltLeft: LandmarkFrame = rotatedAboutWrist(openPalm, degrees: 30)

    /// The mirrored lean, toward the user's right.
    public static let palmTiltRight: LandmarkFrame = rotatedAboutWrist(openPalm, degrees: -30)

    // MARK: - Deliberate (report gestures 18–20)

    /// The open-palm pose enlarged about the wrist — a palm pushed forward, filling more of the
    /// frame.
    public static let palmPush: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: 0, scale: 1.18), [:])

    /// The open-palm pose caught mid-tilt — a single frozen frame of the side-to-side wave.
    public static let wave: LandmarkFrame =
        assemble(transformed(openPalmJoints, pivot: wristPivot, rotationDegrees: 16), [:])

    /// This is a single-hand render of a two-hand gesture: one hand's corner of the "frame" the
    /// pair forms together — thumb extended out to the side, index extended straight up, the
    /// remaining fingers curled clear of the shape.
    public static let twoHandFrame: LandmarkFrame = assemble(
        [
            .indexMCP: jp(0.32, 0.35), .indexPIP: jp(0.32, 0.50), .indexDIP: jp(0.32, 0.58), .indexTip: jp(0.32, 0.65),
            .middleMCP: jp(0.50, 0.35), .middlePIP: jp(0.50, 0.37), .middleDIP: jp(0.50, 0.345), .middleTip: jp(0.50, 0.32),
            .ringMCP: jp(0.62, 0.35), .ringPIP: jp(0.53, 0.38), .ringDIP: jp(0.53, 0.355), .ringTip: jp(0.53, 0.33),
            .littleMCP: jp(0.70, 0.35), .littlePIP: jp(0.55, 0.39), .littleDIP: jp(0.55, 0.365), .littleTip: jp(0.55, 0.34),
        ],
        [.thumbCMC: jp(0.45, 0.22), .thumbMP: jp(0.36, 0.24), .thumbIP: jp(0.28, 0.24), .thumbTip: jp(0.20, 0.24)]
    )

    /// Every canned frame, keyed by `GestureID` — the mapping `GestureCatalog` uses to populate
    /// each entry's `cannedFrame`.
    public static func frame(for id: GestureID) -> LandmarkFrame {
        switch id {
        case .thumbIndexTap: thumbIndexTap
        case .thumbMiddleTap: thumbMiddleTap
        case .indexPoint: indexPoint
        case .victory: victory
        case .thumbsUp: thumbsUp
        case .looseFist: looseFist
        case .openPalm: openPalm
        case .thumbRingPinkyTap: thumbRingPinkyTap
        case .thumbSwipeForward: thumbSwipeForward
        case .thumbSwipeBackward: thumbSwipeBackward
        case .swipeLeft: swipeLeft
        case .swipeRight: swipeRight
        case .swipeUp: swipeUp
        case .swipeDown: swipeDown
        case .fistToOpen: fistToOpen
        case .pinchDrag: pinchDrag
        case .wristRotateCW: wristRotateCW
        case .wristRotateCCW: wristRotateCCW
        case .twoFingerScrollUp: twoFingerScrollUp
        case .twoFingerScrollDown: twoFingerScrollDown
        case .palmTiltLeft: palmTiltLeft
        case .palmTiltRight: palmTiltRight
        case .palmPush: palmPush
        case .wave: wave
        case .twoHandFrame: twoHandFrame
        }
    }
}
