import SwiftUI

/// Project-wide motion tokens (spec §4.5, verbatim). These are the ONLY animation values allowed
/// anywhere in the app — no magic numbers. Every animation in the UI layer must route through
/// one of these tokens, and through `respecting(_:_:)` so Reduce Motion is honored uniformly.
enum TacitMotion {
    static let pressFeedback = Animation.spring(duration: 0.16, bounce: 0)
    static let standardUI    = Animation.spring(duration: 0.25, bounce: 0)
    static let hudIn         = Animation.spring(duration: 0.20, bounce: 0)
    static let hudOut        = Animation.easeOut(duration: 0.16)
    static let armedPulse    = Animation.spring(duration: 0.30, bounce: 0.15)
    static let signature     = Animation.spring(duration: 0.45, bounce: 0.15)
    /// `armedPulse`'s duration as a plain `TimeInterval`, for call sites that need to sequence a
    /// second animation leg after the first one finishes (e.g. the fired-glyph scale pulse's
    /// 1→1.06 leg, then 1.06→1). `Animation` doesn't expose its spring duration introspectably, so
    /// this is the single source of truth — MUST be kept equal to `armedPulse`'s `duration: 0.30`.
    static let armedPulseDuration: TimeInterval = 0.30
    /// Honor Reduce Motion: returns nil (instant) when reduceMotion is on.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
