import Foundation
import Testing
@testable import TacitCore

/// `rotate(SyntheticHand.openPalm(), degrees:t:)` (see `SyntheticHand.swift`) uses the standard
/// math, y-up convention: positive `degrees` is counter-clockwise, which swings the
/// wrist→middleMCP vector toward decreasing x — the user's left, per `PalmTiltDetector`'s roll
/// convention — so a positive rotation reads as `.palmTiltLeft` and a negative one as
/// `.palmTiltRight`. `CannedFrames`'s `rotatedAboutWrist` derives `palmTiltLeft`/`palmTiltRight`
/// with the identical sign convention.
struct PalmTiltDetectorTests {
    private let dt: TimeInterval = 1.0 / 15.0

    @Test func noEmissionBelowEnterThreshold() {
        var detector = PalmTiltDetector()
        // 20° is inside the dead zone (rearmDegrees 10 ..< enterDegrees 25): neither an excursion
        // nor a re-arm.
        let frame = rotate(SyntheticHand.openPalm(), degrees: 20, t: 0)
        #expect(detector.ingest(frame) == nil)
    }

    @Test func emitsAtThirtyDegreesAndClearsTheClutchOffFloorAtFortyDegrees() {
        var atThirty = PalmTiltDetector()
        let thirtyFrame = rotate(SyntheticHand.openPalm(), degrees: 30, t: 0)
        #expect(atThirty.ingest(thirtyFrame) != nil, "30° is past enterDegrees (25°) and should emit")

        var atForty = PalmTiltDetector()
        let fortyFrame = rotate(SyntheticHand.openPalm(), degrees: 40, t: 0)
        let candidate = atForty.ingest(fortyFrame)
        #expect(candidate != nil)
        // ArbitrationTuning's clutch-off floor: enterConfidence (0.6) + clutchOffConfidenceBoost
        // (0.15) = 0.75. fullConfidenceDegrees (40°) is where the ramp tops out at 1.0.
        #expect((candidate?.confidence ?? 0) >= 0.75)
    }

    @Test func leftVsRightSignMatchesTheDocumentedConvention() {
        var leftDetector = PalmTiltDetector()
        // Positive rotation (CCW) swings middleMCP toward decreasing x — the user's left.
        let leftFrame = rotate(SyntheticHand.openPalm(), degrees: 30, t: 0)
        #expect(leftDetector.ingest(leftFrame)?.gesture == .palmTiltLeft)

        var rightDetector = PalmTiltDetector()
        // Negative rotation (CW) swings middleMCP toward increasing x — the user's right.
        let rightFrame = rotate(SyntheticHand.openPalm(), degrees: -30, t: 0)
        #expect(rightDetector.ingest(rightFrame)?.gesture == .palmTiltRight)
    }

    @Test func oneExcursionEmitsABurstThenGoesSilentUntilRearm() {
        var detector = PalmTiltDetector()

        var emissions = 0
        for i in 0..<10 {
            let frame = rotate(SyntheticHand.openPalm(), degrees: 30, t: Double(i) * dt)
            if let candidate = detector.ingest(frame) {
                emissions += 1
                #expect(candidate.gesture == .palmTiltLeft)
            }
        }
        // maxConsecutiveEmissions defaults to ArbitrationTuning().debounceFrames + 1 = 4 — one
        // more than the arbitration engine's own debounce window needs to fire, guaranteeing the
        // fire already happened before the detector goes silent for the rest of the excursion.
        #expect(emissions == ArbitrationTuning().debounceFrames + 1)

        // Still tilted, but the burst is spent: no further emissions without re-arming.
        let stillTilted = rotate(SyntheticHand.openPalm(), degrees: 30, t: 10 * dt)
        #expect(detector.ingest(stillTilted) == nil)

        // Re-arm: |roll| must drop below rearmDegrees (10°) — plain upright openPalm is roll 0.
        let upright = SyntheticHand.openPalm()
        #expect(detector.ingest(upright) == nil)

        // A fresh excursion emits again.
        let tiltedAgain = rotate(SyntheticHand.openPalm(), degrees: 30, t: 12 * dt)
        #expect(detector.ingest(tiltedAgain) != nil)
    }

    @Test func fistAtALargeTiltEmitsNothing() {
        var detector = PalmTiltDetector()
        // A rigid rotation preserves every inter-joint distance, so this still reads as a fist to
        // `StaticPoseClassifier` — `PalmTiltDetector` only computes roll on frames it classifies
        // `.openPalm`.
        let frame = rotate(SyntheticHand.looseFist(), degrees: 35, t: 0)
        #expect(detector.ingest(frame) == nil)
    }
}
