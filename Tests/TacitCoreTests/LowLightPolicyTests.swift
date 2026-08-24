import Foundation
import Testing
@testable import TacitCore

// MARK: - Hysteresis: entering low light

// 1. Below threshold, but for less than `enterAfter`: stays false.
@Test func belowThresholdShortOfEnterAfterStaysFalse() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 2) == false)
    #expect(policy.ingest(luma: 0.05, at: 4.9) == false)
}

// 2. Continuously below threshold for exactly `enterAfter`: flips true.
@Test func continuouslyBelowThresholdForEnterAfterFlipsTrue() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 3) == false)
    #expect(policy.ingest(luma: 0.05, at: 5) == true)
}

// 3. A single bright frame mid-way through the enter window resets the continuous-below run: the
// dark stretch that follows must accumulate another full `enterAfter`, timed from the first
// sample confirmed below threshold again, before flipping — the overall elapsed clock time (well
// past 5s) never flips it on its own, since the run was never *continuous*.
@Test func flickerAboveThresholdDuringEnterWindowResetsTheClock() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 4) == false)
    // Flicker above threshold at t=4.5 — breaks continuity.
    #expect(policy.ingest(luma: 0.5, at: 4.5) == false)
    // Back below at t=5: this sample starts a FRESH run (the flicker means t=4.5's above sample,
    // not t=5, is the most recent boundary) — still false at t=9 (only 4s into the fresh run,
    // short of another full 5s).
    #expect(policy.ingest(luma: 0.05, at: 5) == false)
    #expect(policy.ingest(luma: 0.05, at: 9) == false)
    // A full 5s continuous from the fresh run's start at t=5: flips true at t=10.
    #expect(policy.ingest(luma: 0.05, at: 10) == true)
}

// MARK: - Hysteresis: exiting low light

// 4. Once low, brief return above threshold shorter than `exitAfter` doesn't clear it.
@Test func briefBrightSpikeShorterThanExitAfterStaysLow() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 5) == true)
    // Above threshold for < 3s.
    #expect(policy.ingest(luma: 0.5, at: 6) == true)
    #expect(policy.ingest(luma: 0.5, at: 7.9) == true)
}

// 5. Continuously above threshold for exactly `exitAfter`: flips back to false.
@Test func continuouslyAboveThresholdForExitAfterFlipsFalse() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 5) == true)
    #expect(policy.ingest(luma: 0.5, at: 6) == true)
    #expect(policy.ingest(luma: 0.5, at: 8) == true)
    #expect(policy.ingest(luma: 0.5, at: 9) == false)
}

// 6. A flicker back below threshold during the exit window resets the exit clock — intermittent
// flicker doesn't flip state early.
@Test func flickerBelowThresholdDuringExitWindowResetsTheClock() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.05, at: 0) == false)
    #expect(policy.ingest(luma: 0.05, at: 5) == true)
    #expect(policy.ingest(luma: 0.5, at: 6) == true)
    // Flicker back below at t=7 — breaks the above-threshold continuity.
    #expect(policy.ingest(luma: 0.05, at: 7) == true)
    // Back above again at t=7.5: this sample starts a FRESH run — still true at t=10 (only 2.5s
    // into the fresh run, short of another full 3s).
    #expect(policy.ingest(luma: 0.5, at: 7.5) == true)
    #expect(policy.ingest(luma: 0.5, at: 10) == true)
    // A full 3s continuous from the fresh run's start at t=7.5: flips false at t=10.5.
    #expect(policy.ingest(luma: 0.5, at: 10.5) == false)
}

// 7. Luma exactly at threshold counts as "at or above" (not below) — only strictly-below luma
// counts toward the enter clock.
@Test func lumaExactlyAtThresholdDoesNotCountAsBelow() {
    var policy = LowLightPolicy(lumaThreshold: 0.18, enterAfter: 5, exitAfter: 3)
    #expect(policy.ingest(luma: 0.18, at: 0) == false)
    #expect(policy.ingest(luma: 0.18, at: 10) == false)
}

// MARK: - adjusted(): confidence raise while low, full-field carry-through

// 8. lowLight == false returns the tuning completely unchanged.
@Test func adjustedWhenNotLowLightReturnsTuningUnchanged() {
    var tuning = ArbitrationTuning()
    tuning.clutchHold = 0.4
    tuning.commandWindow = 4.0
    tuning.debounceFrames = 3
    tuning.cooldown = 0.8
    tuning.repeatCooldown = 0.2
    tuning.postArmSuppression = 0.6
    tuning.enterConfidence = 0.6
    tuning.stayConfidence = 0.45

    let result = LowLightPolicy.adjusted(tuning, lowLight: false)

    #expect(result.clutchHold == tuning.clutchHold)
    #expect(result.commandWindow == tuning.commandWindow)
    #expect(result.debounceFrames == tuning.debounceFrames)
    #expect(result.cooldown == tuning.cooldown)
    #expect(result.repeatCooldown == tuning.repeatCooldown)
    #expect(result.postArmSuppression == tuning.postArmSuppression)
    #expect(result.enterConfidence == tuning.enterConfidence)
    #expect(result.stayConfidence == tuning.stayConfidence)
}

// 9. lowLight == true raises enterConfidence/stayConfidence by 0.1 and carries EVERY other field
// through untouched — a dropped field here (e.g. `postArmSuppression`) would silently reopen the
// fistToOpen post-arm suppression hole while low light is active.
@Test func adjustedWhenLowLightRaisesConfidenceAndCarriesEveryOtherFieldThrough() {
    var tuning = ArbitrationTuning()
    tuning.clutchHold = 0.37
    tuning.commandWindow = 4.21
    tuning.debounceFrames = 5
    tuning.cooldown = 0.91
    tuning.repeatCooldown = 0.23
    tuning.postArmSuppression = 0.77
    tuning.enterConfidence = 0.6
    tuning.stayConfidence = 0.45

    let result = LowLightPolicy.adjusted(tuning, lowLight: true)

    // Untouched fields — carried through exactly, including postArmSuppression.
    #expect(result.clutchHold == tuning.clutchHold)
    #expect(result.commandWindow == tuning.commandWindow)
    #expect(result.debounceFrames == tuning.debounceFrames)
    #expect(result.cooldown == tuning.cooldown)
    #expect(result.repeatCooldown == tuning.repeatCooldown)
    #expect(result.postArmSuppression == tuning.postArmSuppression)

    // Adjusted fields.
    #expect(abs(result.enterConfidence - 0.7) < 0.0001)
    #expect(abs(result.stayConfidence - 0.55) < 0.0001)
}

// 10. The +0.1 raise clamps at 0.95 rather than overshooting past it.
@Test func adjustedClampsConfidenceAt095() {
    var tuning = ArbitrationTuning()
    tuning.enterConfidence = 0.9
    tuning.stayConfidence = 0.88

    let result = LowLightPolicy.adjusted(tuning, lowLight: true)

    #expect(abs(result.enterConfidence - 0.95) < 0.0001)
    #expect(abs(result.stayConfidence - 0.95) < 0.0001)
}
