import Foundation

/// Pure label-sanitize + filename-format logic for fixture recordings (Task 10), split out of
/// `FixtureRecorder` (which lives in the `Tacit` app target, alongside AppKit/SwiftUI) so it's
/// unit-testable in `TacitCoreTests` without any UI or file-system dependency.
public enum FixtureNaming {
    /// Builds `<sanitized-label>-<yyyyMMdd-HHmmss>.json`.
    ///
    /// - Parameters:
    ///   - label: Free-text label from the debug UI; sanitized to `[a-z0-9-]`, falling back to
    ///     `"fixture"` if that leaves nothing.
    ///   - date: The moment to stamp the filename with (recorder passes `Date()`; tests pass a
    ///     fixed `Date` for determinism).
    ///   - timeZone: Defaults to `.current` for real use; tests pass a fixed zone (e.g. `.gmt`) so
    ///     the formatted timestamp is deterministic regardless of the machine running the test.
    public static func filename(label: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(sanitize(label))-\(formatter.string(from: date)).json"
    }

    /// Lowercases, maps any run of non-`[a-z0-9]` characters to a single `-`, and trims leading/
    /// trailing dashes. Empty (or entirely-non-alphanumeric) input becomes `"fixture"`.
    static func sanitize(_ label: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var result = ""
        var pendingDash = false
        for scalar in label.lowercased().unicodeScalars {
            let character = Character(scalar)
            if allowed.contains(character) {
                if pendingDash && !result.isEmpty {
                    result.append("-")
                }
                result.append(character)
                pendingDash = false
            } else if !result.isEmpty {
                pendingDash = true
            }
        }
        return result.isEmpty ? "fixture" : result
    }
}
