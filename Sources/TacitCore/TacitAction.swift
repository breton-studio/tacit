import Foundation

/// The action a gesture triggers once mapped.
///
/// NOTE (spec §3.5 deviation, approved rationale): the spec sketches a protocol; an enum with
/// associated values gives Codable+Equatable for free and is the same App Store seam — the
/// sandboxed variant simply refuses .keystroke at dispatch. Do not "fix" this back to a protocol.
public enum TacitAction: Codable, Equatable, Sendable {
    case keystroke(KeyChord)
    case launchApp(bundleID: String, displayName: String)
    case openURL(String)
    case runShortcut(name: String)
    /// M3 Task 9: a keystroke held down for the duration of a `HoldTracker` hold — key-down on
    /// `.began`, key-up on `.ended` — rather than a single instantaneous press. The engine routes
    /// this case's began/ended lifecycle directly to `ActionEnvironment.postKeyDown`/`postKeyUp`,
    /// never through `ActionDispatcher.dispatch(_:)`'s normal fire path; `dispatch(_:)` itself
    /// still handles a bare *fire* of a `.holdKeystroke`-bound gesture (a momentary gesture bound
    /// to this action has no hold to speak of) by falling back to a full press — down then up.
    /// Codable via synthesis: adding this case is backward-compatible for old `mappings.json`
    /// files, which simply never contain it.
    case holdKeystroke(KeyChord)

    /// True for `.keystroke` and `.holdKeystroke` — the only cases that need Accessibility
    /// permission to actually perform (posting a synthetic key event).
    public var requiresAccessibility: Bool {
        switch self {
        case .keystroke, .holdKeystroke: true
        case .launchApp, .openURL, .runShortcut: false
        }
    }

    /// A short user-facing description of the action, e.g. for a mapping list row.
    public var summary: String {
        switch self {
        case .keystroke(let chord): chord.display
        case .holdKeystroke(let chord): "Hold " + (chord.keyCode == 63 ? "Fn" : chord.display)
        case .launchApp(_, let displayName): "Open \(displayName)"
        case .openURL(let string): string
        case .runShortcut(let name): "Shortcut: \(name)"
        }
    }
}
