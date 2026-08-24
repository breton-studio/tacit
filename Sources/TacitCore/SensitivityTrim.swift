import Foundation

/// The Settings tab's global arbitration sensitivity trim (spec §5: "arbitration sensitivity
/// global trim"). A blunt, three-position knob over `ArbitrationTuning`'s confidence/debounce
/// fields — NOT a replacement for `LowLightPolicy`'s adjustment, which composes on top of this
/// (see `applied(to:)`'s doc comment for the composition order).
///
/// `relaxed` loosens the confidence/debounce floor a hand has to clear before a gesture is
/// recognized (more forgiving, more false positives); `eager` tightens it the other way (fires
/// faster/more readily, at the cost of a lower confidence bar); `standard` is the shipped default
/// tuning, untouched.
public enum SensitivityTrim: String, Codable, CaseIterable, Sendable {
    case relaxed, standard, eager

    /// Confidence fields never leave the `0.3...1.0` range: `eager`'s subtraction floors at 0.3
    /// (a lower bar would recognize essentially anything) and, symmetrically, no adjustment here
    /// is ever allowed to push a confidence above 1.0 (which would already be nonsensical for a
    /// probability-like value).
    private static let confidenceFloor = 0.3
    private static let confidenceCeiling = 1.0

    /// Applies this trim to `tuning`, returning a new `ArbitrationTuning`.
    ///
    /// - `.relaxed`: `enterConfidence`/`stayConfidence` raised by 0.08 (harder to start/continue a
    ///   debounce — fewer false positives, slower to fire), `debounceFrames` set to 4.
    /// - `.standard`: `tuning` returned unchanged.
    /// - `.eager`: `enterConfidence`/`stayConfidence` lowered by 0.05, floored at 0.3 (easier to
    ///   start/continue a debounce — fires faster), `debounceFrames` set to 2.
    ///
    /// Every other field (`clutchHold`, `commandWindow`, `cooldown`, `repeatCooldown`,
    /// `postArmSuppression`) is carried through untouched via the `var` copy below — carried
    /// STRUCTURALLY (copy the whole struct, mutate only the fields this trim actually changes)
    /// rather than by enumerating every field, so a future `ArbitrationTuning` field added
    /// elsewhere is carried through this trim for free, with no matching edit required here.
    ///
    /// Composition order (documented per M3 Task 7's brief; enforced by `PipelineCore` in
    /// `Sources/Tacit/TacitEngine.swift`, not here): **base `ArbitrationTuning()` → `applied(to:)`
    /// → `LowLightPolicy.adjusted(_, lowLight:)`.** Sensitivity is the user's own persistent
    /// preference; low light is a live, transient condition that further raises confidence on top
    /// of whatever the sensitivity trim already set — never the other way around, and never
    /// re-deriving from a sensitivity-adjusted tuning that never gets reset back to the trim's own
    /// baseline once low light clears.
    public func applied(to tuning: ArbitrationTuning) -> ArbitrationTuning {
        var result = tuning
        switch self {
        case .relaxed:
            result.enterConfidence = clamp(tuning.enterConfidence + 0.08)
            result.stayConfidence = clamp(tuning.stayConfidence + 0.08)
            result.debounceFrames = 4
        case .standard:
            break
        case .eager:
            result.enterConfidence = clamp(tuning.enterConfidence - 0.05)
            result.stayConfidence = clamp(tuning.stayConfidence - 0.05)
            result.debounceFrames = 2
        }
        return result
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, Self.confidenceFloor), Self.confidenceCeiling)
    }
}
