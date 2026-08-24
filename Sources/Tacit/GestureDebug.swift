import Foundation
import TacitCore

/// A per-frame snapshot of the pipeline's live state, purpose-built for the gesture debug panel
/// (`GestureDebugPanelController`/`GestureDebugView`) — the "SEE the live reading" feature the user
/// asked for after watching their clutch flicker `arming → disarmed` ten times before arming, then
/// misfire on gestures they never meant to make.
///
/// Populated by `TacitEngine.apply(_:generation:timestamp:)` ONLY while `isDebugViewEnabled` is
/// `true` — every field here is either already computed for other purposes that frame (`frame`,
/// `arbitration`) or a cheap read (`AXIsProcessTrusted()`, `lowLightPolicy.isLowLight`), so the
/// panel being off costs nothing beyond the one `if isDebugViewEnabled` branch.
///
/// `staticCandidate` is deliberately populated from `PipelineCore.Result.staticCandidate` —
/// `classifier.classify`'s raw result, computed BEFORE any clutch/arbitration gating — so the
/// panel can show what the classifier thinks the hand is doing even while disarmed. That's the
/// whole point: a user tuning their hand/camera needs to see the reading that never made it past
/// the clutch, not just the gated events that did.
struct GestureDebugSnapshot: Equatable, Sendable {
    var frame: LandmarkFrame?
    var handDetected: Bool
    var staticCandidate: GestureCandidate?
    var arbitration: ArbitrationState
    var lastFired: GestureID?
    var lastFiredAt: TimeInterval?
    var isLowLight: Bool
    var isAccessibilityTrusted: Bool
    var timestamp: TimeInterval
    /// Clutch-optional setting (2026-08-24): mirrors `TacitEngine.requiresClutch` — the Clutch row
    /// in `GestureDebugView` shows "Off" instead of the usual disarmed/arming/armed reading
    /// whenever this is `false`, since arbitration is then always reported `.armed` and the normal
    /// reading would be meaningless noise.
    var requiresClutch: Bool
}
