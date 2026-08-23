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
    /// The HUD's constellation draw-on (spec §4 motion table, "HUD constellation draw-on" row):
    /// `drawProgress` 0→1, 250 ms ease-out, concurrent with — but a distinct curve/duration
    /// from — `hudIn`. Not one of §4.5's five named token categories; added here anyway so the
    /// value stays a single source of truth rather than a literal at the call site.
    static let hudConstellationDrawOn = Animation.easeOut(duration: 0.25)
    /// HUD dwell (spec §4 motion table, "HUD out" row's trigger): how long the HUD holds at rest
    /// before `hudOut` plays. Sanctioned addition per Task 16's brief.
    static let hudDwell: TimeInterval = 0.8
    /// `armedPulse`'s duration as a plain `TimeInterval`, for call sites that need to sequence a
    /// second animation leg after the first one finishes (e.g. the fired-glyph scale pulse's
    /// 1→1.06 leg, then 1.06→1). `Animation` doesn't expose its spring duration introspectably, so
    /// this is the single source of truth — MUST be kept equal to `armedPulse`'s `duration: 0.30`.
    static let armedPulseDuration: TimeInterval = 0.30
    /// Card grid first appearance (spec §4 motion table, "Card grid first appearance" row):
    /// opacity 0→1 + translateY 8→0, 200 ms ease-out per card. The per-card stagger delay
    /// (30 ms/card, capped at 300 ms total) is computed at the call site and applied via
    /// `Animation.delay(_:)` on top of this token; Reduce Motion drops the stagger (delay 0) but
    /// still plays this same fade.
    static let cardAppear = Animation.easeOut(duration: 0.2)
    /// Honor Reduce Motion: returns nil (instant) when reduceMotion is on.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
