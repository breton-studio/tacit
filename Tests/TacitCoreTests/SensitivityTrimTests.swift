import Foundation
import Testing
@testable import TacitCore

// MARK: - The three mappings, exact

@Test func relaxedRaisesConfidenceByPointZeroEightAndSetsDebounceFramesFour() {
    var tuning = ArbitrationTuning()
    tuning.enterConfidence = 0.6
    tuning.stayConfidence = 0.45
    tuning.debounceFrames = 3

    let result = SensitivityTrim.relaxed.applied(to: tuning)

    #expect(abs(result.enterConfidence - 0.68) < 0.0001)
    #expect(abs(result.stayConfidence - 0.53) < 0.0001)
    #expect(result.debounceFrames == 4)
}

@Test func standardReturnsTuningUnchanged() {
    var tuning = ArbitrationTuning()
    tuning.clutchHold = 0.37
    tuning.commandWindow = 4.21
    tuning.debounceFrames = 5
    tuning.cooldown = 0.91
    tuning.repeatCooldown = 0.23
    tuning.postArmSuppression = 0.77
    tuning.enterConfidence = 0.6
    tuning.stayConfidence = 0.45

    let result = SensitivityTrim.standard.applied(to: tuning)

    #expect(result.clutchHold == tuning.clutchHold)
    #expect(result.commandWindow == tuning.commandWindow)
    #expect(result.debounceFrames == tuning.debounceFrames)
    #expect(result.cooldown == tuning.cooldown)
    #expect(result.repeatCooldown == tuning.repeatCooldown)
    #expect(result.postArmSuppression == tuning.postArmSuppression)
    #expect(result.enterConfidence == tuning.enterConfidence)
    #expect(result.stayConfidence == tuning.stayConfidence)
}

@Test func eagerLowersConfidenceByPointZeroFiveAndSetsDebounceFramesTwo() {
    var tuning = ArbitrationTuning()
    tuning.enterConfidence = 0.6
    tuning.stayConfidence = 0.45
    tuning.debounceFrames = 3

    let result = SensitivityTrim.eager.applied(to: tuning)

    #expect(abs(result.enterConfidence - 0.55) < 0.0001)
    #expect(abs(result.stayConfidence - 0.40) < 0.0001)
    #expect(result.debounceFrames == 2)
}

// MARK: - Floors: eager's subtraction never drops a confidence below 0.3

@Test func eagerFloorsConfidenceAtPointThreeRatherThanOvershooting() {
    var tuning = ArbitrationTuning()
    tuning.enterConfidence = 0.32
    tuning.stayConfidence = 0.33

    let result = SensitivityTrim.eager.applied(to: tuning)

    #expect(abs(result.enterConfidence - 0.3) < 0.0001)
    #expect(abs(result.stayConfidence - 0.3) < 0.0001)
}

// MARK: - Full-field carry: every untouched field survives structurally, both directions

@Test func relaxedCarriesEveryUntouchedFieldThrough() {
    var tuning = ArbitrationTuning()
    tuning.clutchHold = 0.37
    tuning.commandWindow = 4.21
    tuning.cooldown = 0.91
    tuning.repeatCooldown = 0.23
    tuning.postArmSuppression = 0.77

    let result = SensitivityTrim.relaxed.applied(to: tuning)

    #expect(result.clutchHold == tuning.clutchHold)
    #expect(result.commandWindow == tuning.commandWindow)
    #expect(result.cooldown == tuning.cooldown)
    #expect(result.repeatCooldown == tuning.repeatCooldown)
    #expect(result.postArmSuppression == tuning.postArmSuppression)
}

@Test func eagerCarriesEveryUntouchedFieldThrough() {
    var tuning = ArbitrationTuning()
    tuning.clutchHold = 0.29
    tuning.commandWindow = 3.5
    tuning.cooldown = 0.65
    tuning.repeatCooldown = 0.17
    tuning.postArmSuppression = 0.5

    let result = SensitivityTrim.eager.applied(to: tuning)

    #expect(result.clutchHold == tuning.clutchHold)
    #expect(result.commandWindow == tuning.commandWindow)
    #expect(result.cooldown == tuning.cooldown)
    #expect(result.repeatCooldown == tuning.repeatCooldown)
    #expect(result.postArmSuppression == tuning.postArmSuppression)
}

// MARK: - Composition with LowLightPolicy.adjusted: sensitivity first, then low light on top

// `eager` alone takes the default 0.6/0.45 down to 0.55/0.40; low light then raises FROM that
// eager baseline (not from the un-sensitized default), landing at 0.65/0.50.
@Test func eagerThenLowLightComposesFromTheEagerBaseline() {
    let base = ArbitrationTuning()
    let sensitized = SensitivityTrim.eager.applied(to: base)
    #expect(abs(sensitized.enterConfidence - 0.55) < 0.0001)
    #expect(abs(sensitized.stayConfidence - 0.40) < 0.0001)

    let composed = LowLightPolicy.adjusted(sensitized, lowLight: true)

    #expect(abs(composed.enterConfidence - 0.65) < 0.0001)
    #expect(abs(composed.stayConfidence - 0.50) < 0.0001)
    // debounceFrames is untouched by LowLightPolicy — eager's value survives composition.
    #expect(composed.debounceFrames == 2)
}

// Composition still clamps at 0.95 even starting from an eager-adjusted (lower) baseline that's
// nowhere near the ceiling on its own — the ceiling is `LowLightPolicy.adjusted`'s, applied AFTER
// sensitivity, not something sensitivity itself needs to guard against here.
@Test func eagerThenLowLightStillClampsAtPointNineFive() {
    var base = ArbitrationTuning()
    base.enterConfidence = 0.9
    base.stayConfidence = 0.92
    let sensitized = SensitivityTrim.eager.applied(to: base)

    let composed = LowLightPolicy.adjusted(sensitized, lowLight: true)

    #expect(abs(composed.enterConfidence - 0.95) < 0.0001)
    #expect(abs(composed.stayConfidence - 0.95) < 0.0001)
}
