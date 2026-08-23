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

    /// True only for `.keystroke` — the only case that needs Accessibility permission to
    /// actually perform (posting a synthetic key event).
    public var requiresAccessibility: Bool {
        switch self {
        case .keystroke: true
        case .launchApp, .openURL, .runShortcut: false
        }
    }

    /// A short user-facing description of the action, e.g. for a mapping list row.
    public var summary: String {
        switch self {
        case .keystroke(let chord): chord.display
        case .launchApp(_, let displayName): "Open \(displayName)"
        case .openURL(let string): string
        case .runShortcut(let name): "Shortcut: \(name)"
        }
    }
}
