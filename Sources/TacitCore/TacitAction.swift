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

    /// M3 Task 10: finds and focuses the frontmost window's main text input via the Accessibility
    /// API (no configuration — unlike every other case, it carries no associated value). The
    /// search itself lives in the app target (`LiveActionEnvironment`, since `TacitCore` stays
    /// Foundation-only and can't import `ApplicationServices`); this case is just the routing
    /// token `ActionDispatcher` matches on. Codable via synthesis: adding this case is
    /// backward-compatible for old `mappings.json` files, which simply never contain it.
    case focusTextInput

    /// True for `.keystroke`, `.holdKeystroke`, and `.focusTextInput` — the cases that need
    /// Accessibility permission to actually perform (posting a synthetic key event, or reading/
    /// setting attributes on another app's UI elements via the AX API).
    public var requiresAccessibility: Bool {
        switch self {
        case .keystroke, .holdKeystroke, .focusTextInput: true
        case .launchApp, .openURL, .runShortcut: false
        }
    }

    /// A short user-facing description of the action, e.g. for a mapping list row.
    public var summary: String {
        switch self {
        case .keystroke(let chord): chord.display
        // `KeyChord.capNames` maps keyCode 63 to "Fn", so the default hold-to-dictate binding
        // (`.holdKeystroke(KeyChord(keyCode: 63, ...))`) reads as "Hold Fn" via plain `.display` —
        // no special case needed here.
        case .holdKeystroke(let chord): "Hold " + chord.display
        case .launchApp(_, let displayName): "Open \(displayName)"
        case .openURL(let string): string
        case .runShortcut(let name): "Shortcut: \(name)"
        case .focusTextInput: "Focus text input"
        }
    }
}
