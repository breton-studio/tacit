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
    /// Honor Reduce Motion: returns nil (instant) when reduceMotion is on.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
