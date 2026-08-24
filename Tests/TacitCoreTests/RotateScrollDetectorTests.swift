import Foundation
import Testing
@testable import TacitCore

// MARK: - Synthetic motion helpers
//
// `rotate`/`shift` now live in `SyntheticHand.swift` (shared test-support, Task 5) — see that
// file's doc comment for why.

// Shared arithmetic for every rotate test below: `SyntheticHand.looseFist()` has wrist at
// (0.5, 0.2) and middleMCP at (0.50, 0.35), so the wrist→middleMCP vector is (0, 0.15) and its
// angle is atan2(0.15, 0) = 90°. Rotating the whole hand by θ around the wrist moves that vector's
// angle by exactly θ (rotation is angle-preserving), so cumulative rotation degrees == the
// detector's accumulated `netArcDegrees` exactly, with no lossy geometry to account for.
// `WristRotateDetector()` defaults: tickArcDegrees = 20, maxArcDegrees = 70.

// MARK: - Basic sweeps

@Test func fortyFiveDegreeClockwiseSweepEmitsExactlyTwoCWTicks() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    // Clockwise = decreasing atan2 angle = negative rotation degrees by this file's `rotate`
    // convention. Baseline frame at cumulative 0° (engages tracking, emits nothing), then 9
    // steps of -5° reaching cumulative -45° at i=9.
    for i in 0...9 {
        let cumulative = Double(-5 * i)
        if let candidate = detector.ingest(rotate(base, degrees: cumulative, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // magnitude = 5*i: crosses the first tick threshold (20°) at i=4 (mag 20, level 0->1), and
    // the second (40°) at i=8 (mag 40, level 1->2). At i=9, mag=45, level = floor(45/20) = 2 —
    // unchanged from i=8, so no third tick. Exactly 2 ticks, both clockwise (netArc < 0
    // throughout).
    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .wristRotateCW })
}

@Test func fortyFiveDegreeCounterClockwiseSweepEmitsCCWTicks() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    // Mirror of the CW sweep: positive cumulative rotation degrees.
    for i in 0...9 {
        let cumulative = Double(5 * i)
        if let candidate = detector.ingest(rotate(base, degrees: cumulative, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // Identical magnitude arithmetic to the CW case (mag = 5*i), so ticks at i=4 (20°) and i=8
    // (40°) — exactly 2 ticks, both counter-clockwise (netArc > 0 throughout).
    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .wristRotateCCW })
}

@Test func ninetyDegreeSweepClampsAtThreeTicksThenGoesSilent() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    // 9 steps of -10° reaching cumulative -90° at i=9.
    for i in 0...9 {
        let cumulative = Double(-10 * i)
        if let candidate = detector.ingest(rotate(base, degrees: cumulative, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // magnitude = 10*i: ticks at i=2 (20°, level 0->1), i=4 (40°, level 1->2), i=6 (60°,
    // level 2->3 — level is capped at maxTicks = floor(70/20) = 3). At i=7, magnitude reaches 70:
    // level stays capped at 3 (no 4th tick), and 70 >= maxArcDegrees (70) trips the clamp, so
    // i=8 (80°) and i=9 (90°) stay silent even though they're well past the third tick's
    // threshold. Exactly 3 ticks, all clockwise.
    #expect(emitted.count == 3)
    #expect(emitted.allSatisfy { $0.gesture == .wristRotateCW })
}

@Test func openHandRotationEmitsNothing() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...9 {
        let cumulative = Double(-10 * i)
        if let candidate = detector.ingest(rotate(base, degrees: cumulative, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // Same 90° sweep as the clamp test, but the hand is open throughout: the fisted precondition
    // fails on every frame (all four non-thumb fingers read as extended, not curled), so tracking
    // never engages regardless of the motion.
    #expect(emitted.isEmpty)
}

// MARK: - Wraparound across the ±180° seam

@Test func rotationAcrossThePlusMinus180SeamTicksCorrectly() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    // Baseline is looseFist rotated +80° up front (angle = 90 + 80 = 170°), then +5° per frame:
    // i=0 -> angle 170 (baseline, engages, netArc 0)
    // i=1 -> angle 175 (delta +5,  netArc  5)
    // i=2 -> angle 180 (delta +5,  netArc 10)
    // i=3 -> angle -175 (raw would-be 185 wraps to -175; wrappedDelta from 180 is
    //         (-175 - 180) = -355, which wraps by +360 to +5,           netArc 15)
    // i=4 -> angle -170 (delta from -175 is +5 -- no wrap needed here,  netArc 20 -> tick!)
    // If the ±180° wrap weren't handled, the i=3 step would register as a spurious -355° jump
    // instead of +5°, and this sweep would never reach a clean +20° tick.
    for i in 0...4 {
        let cumulative = 80 + Double(5 * i)
        if let candidate = detector.ingest(rotate(base, degrees: cumulative, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .wristRotateCCW)
}

// MARK: - Direction flip mid-sweep

@Test func directionFlipMidSweepEmitsNoPhantomTicksAndOnlyTheFinalDirection() {
    var detector = WristRotateDetector()
    let base = SyntheticHand.looseFist()
    var emitted: [GestureCandidate] = []

    // Cumulative rotation degrees, one frame per entry, 0.05s apart: winds clockwise to -15°
    // (magnitude 15, under the 20° tick threshold -- no tick), then reverses through 0 and winds
    // counter-clockwise out to +40°.
    let cumulative: [Double] = [0, -5, -10, -15, -10, -5, 0, 5, 10, 15, 20, 25, 30, 35, 40]
    for (i, degrees) in cumulative.enumerated() {
        if let candidate = detector.ingest(rotate(base, degrees: degrees, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // netArc tracks `degrees` exactly (angle-preserving rotation from a 0°-baseline). magnitude
    // peaks at 15 on the clockwise side (level floor(15/20) = 0 -- no tick), then falls back to 0
    // and climbs the counter-clockwise side: level crosses to 1 at magnitude 20 (a CCW tick) and
    // to 2 at magnitude 40 (a second CCW tick). The clockwise excursion never reached level 1, so
    // reversing direction cost the full trip back through zero before any tick could fire --
    // no cross-direction credit, and critically no phantom clockwise tick on the way back down.
    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .wristRotateCCW })
}

// MARK: - TwoFingerScrollDetector

// Shared arithmetic: `SyntheticHand.victory()` already satisfies TwoFingerScrollDetector's
// engagement condition (index + middle extended, ring + little curled -- the tip *spread* that
// makes it read as "victory" to `StaticPoseClassifier` is irrelevant here, since this detector
// never checks tip spread, only per-finger extension). Palm size (wrist->middleMCP) is 0.15 for
// every `SyntheticHand` pose. `TwoFingerScrollDetector()`'s default tickTravel = 0.35.

@Test func twoFingerDownTravelOfZeroPointEightPalmUnitsEmitsTwoDownTicks() {
    var detector = TwoFingerScrollDetector()
    let base = SyntheticHand.victory()
    var emitted: [GestureCandidate] = []

    // 8 steps of raw dy = -0.015 (= -0.015/0.15 = -0.1 palm-units each), reaching cumulative
    // -0.8 palm-units (raw -0.12) at i=8. "Down" = decreasing y, per the y-up convention.
    for i in 0...8 {
        let dy = -0.015 * Double(i)
        if let candidate = detector.ingest(shift(base, dx: 0, dy: dy, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // magnitude in palm-units = 0.1*i: crosses the first tick threshold (0.35) at i=4
    // (mag 0.4, level 0->1) and the second at i=7 (mag 0.7 == 2*0.35 exactly, level 1->2).
    // At i=8, mag=0.8, level = floor(0.8/0.35) = 2 -- unchanged, no third tick. Exactly 2 ticks,
    // both down (netTravel < 0 throughout).
    #expect(emitted.count == 2)
    #expect(emitted.allSatisfy { $0.gesture == .twoFingerScrollDown })
}

@Test func sameDownTravelWithAllFingersExtendedEmitsNothing() {
    var detector = TwoFingerScrollDetector()
    let base = SyntheticHand.openPalm()
    var emitted: [GestureCandidate] = []

    for i in 0...8 {
        let dy = -0.015 * Double(i)
        if let candidate = detector.ingest(shift(base, dx: 0, dy: dy, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // Identical travel to the passing case, but ring and little read as extended (openPalm), so
    // the "exactly index+middle extended, ring+little curled" precondition fails on every frame
    // -- tracking never engages regardless of the motion.
    #expect(emitted.isEmpty)
}

@Test func scrollDirectionFlipEmitsNoPhantomTicksAndOnlyTheFinalDirection() {
    var detector = TwoFingerScrollDetector()
    let base = SyntheticHand.victory()
    var emitted: [GestureCandidate] = []

    // Cumulative vertical travel in palm-units, one frame per entry, raw dy = palmUnits * 0.15:
    // scrolls down to -0.3 (under the 0.35 tick threshold -- no tick), reverses through 0, and
    // scrolls up to +0.4.
    let palmUnitSteps: [Double] = [0, -0.1, -0.2, -0.3, -0.2, -0.1, 0, 0.1, 0.2, 0.3, 0.4]
    for (i, palmUnits) in palmUnitSteps.enumerated() {
        let dy = palmUnits * 0.15
        if let candidate = detector.ingest(shift(base, dx: 0, dy: dy, t: Double(i) * 0.05)) {
            emitted.append(candidate)
        }
    }

    // netTravel tracks `palmUnits` exactly (a rigid translation from a 0-baseline, divided back
    // out by the same 0.15 palm size). The downward excursion peaks at magnitude 0.3 (level
    // floor(0.3/0.35) = 0 -- no tick), falls back to 0, and only crosses level 1 on the upward
    // side at magnitude 0.4. Exactly 1 tick, scrolling up -- no phantom down tick.
    #expect(emitted.count == 1)
    #expect(emitted.first?.gesture == .twoFingerScrollUp)
}
