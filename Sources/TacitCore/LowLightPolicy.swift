import Foundation

/// Pure, deterministic hysteresis policy over sampled mean-luma readings (spec §6 low-light row,
/// M3 Task 6 ruling 6: "luma sampled in the app layer; the POLICY is pure core and TDD'd").
///
/// Like `ArbitrationEngine`, this holds zero wall-clock state and makes zero calls to `Date()` —
/// every transition is driven entirely by the `now:` timestamp passed to `ingest`, so fixture
/// replay stays fully deterministic.
///
/// ## Hysteresis
///
/// The policy tracks the length of the current *unbroken* run of samples below (or at/above) the
/// threshold, from the timestamp that run started. A single sample on the other side of the
/// threshold — even briefly — resets that run's start, so intermittent flicker right at the
/// threshold can delay a flip indefinitely (as long as it keeps flickering) but can never cause a
/// spurious one: only a truly continuous `enterAfter` (to flip low) or `exitAfter` (to flip back)
/// stretch flips the state, mirroring `ArbitrationEngine.processClutch`'s own
/// `elapsed >= tuning.clutchHold` pattern.
public struct LowLightPolicy: Sendable {
    public let lumaThreshold: Double
    public let enterAfter: TimeInterval
    public let exitAfter: TimeInterval

    /// Current hysteresis state — mirrors what the most recent `ingest` call returned.
    public private(set) var isLowLight = false

    /// Timestamp at which the current unbroken "below threshold" run began, nil while the most
    /// recent sample was at/above threshold.
    private var belowRunStartedAt: TimeInterval?
    /// Timestamp at which the current unbroken "at/above threshold" run began, nil while the most
    /// recent sample was below threshold.
    private var aboveRunStartedAt: TimeInterval?

    public init(lumaThreshold: Double = 0.18, enterAfter: TimeInterval = 5, exitAfter: TimeInterval = 3) {
        self.lumaThreshold = lumaThreshold
        self.enterAfter = enterAfter
        self.exitAfter = exitAfter
    }

    /// Feed one sampled mean luma (0…1) + its capture timestamp. Returns the (possibly just
    /// updated) low-light state.
    @discardableResult
    public mutating func ingest(luma: Double, at now: TimeInterval) -> Bool {
        if luma < lumaThreshold {
            aboveRunStartedAt = nil
            let startedAt = belowRunStartedAt ?? now
            belowRunStartedAt = startedAt
            if !isLowLight, now - startedAt >= enterAfter {
                isLowLight = true
            }
        } else {
            belowRunStartedAt = nil
            let startedAt = aboveRunStartedAt ?? now
            aboveRunStartedAt = startedAt
            if isLowLight, now - startedAt >= exitAfter {
                isLowLight = false
            }
        }
        return isLowLight
    }

    /// Raises `enterConfidence`/`stayConfidence` by 0.1 (clamped to ≤0.95) while low light is in
    /// effect, so a dim room requires a more confident hold before a gesture starts/continues
    /// debouncing — every other tuning field (`clutchHold`, `commandWindow`, `debounceFrames`,
    /// `cooldown`, `repeatCooldown`, `postArmSuppression`) is carried through completely
    /// untouched. That completeness matters: a dropped `postArmSuppression` here would silently
    /// reopen the fistToOpen post-arm suppression hole (see `ArbitrationTuning.postArmSuppression`)
    /// for the entire time the room stays dim.
    ///
    /// `lowLight == false` returns `tuning` unchanged — callers can call this unconditionally on
    /// every flip without a branch of their own.
    public static func adjusted(_ tuning: ArbitrationTuning, lowLight: Bool) -> ArbitrationTuning {
        guard lowLight else { return tuning }
        var adjusted = tuning
        adjusted.enterConfidence = min(tuning.enterConfidence + 0.1, 0.95)
        adjusted.stayConfidence = min(tuning.stayConfidence + 0.1, 0.95)
        return adjusted
    }
}
