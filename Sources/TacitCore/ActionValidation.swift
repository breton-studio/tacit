import Foundation

/// Validation helpers for user-entered action data — currently just the Open URL binder's text
/// field (`ActionBinders.swift`).
public enum ActionValidation {
    /// True for any string with a non-empty URL scheme — `"superwhisper://record"`,
    /// `"https://example.com"`, `"raycast://confetti"` — false for schemeless input
    /// (`"hello"`, `"example.com"`) and the empty string.
    ///
    /// `URL(string:)` alone isn't enough: it happily parses schemeless strings like `"hello"` or
    /// `"example.com"` into a URL whose `scheme` is simply `nil`, so this checks `URLComponents`'s
    /// `scheme` explicitly for both existence and non-emptiness rather than trusting `URL` to
    /// reject those on its own.
    public static func validateURL(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        guard let components = URLComponents(string: s) else { return false }
        guard let scheme = components.scheme else { return false }
        return !scheme.isEmpty
    }
}
