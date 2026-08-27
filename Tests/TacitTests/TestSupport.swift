import Foundation
import TacitCore
@testable import Tacit

/// Shared construction helpers for `TacitTests` (code review 2026-08-27, Finding 2 / item (d)).
public enum TacitTestSupport {
    /// A `MappingStore` isolated to a fresh temp directory + a fresh `UserDefaults` suite, so a
    /// test's `setBinding(_:for:)` calls never read or write the real
    /// `~/Library/Application Support/Tacit/mappings.json` (or its defaults-revision stamp under
    /// `UserDefaults.standard`) that a real install on the machine running the tests would use.
    /// Every call returns a brand-new, independent store — safe to call once per test.
    @MainActor
    public static func isolatedMappingStore() -> MappingStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TacitTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "TacitTests.\(UUID().uuidString)"
        // Force-unwrap is safe: `UserDefaults(suiteName:)` only returns `nil` for an invalid suite
        // name (e.g. one matching a reserved domain) — a fresh UUID-suffixed name never collides.
        let userDefaults = UserDefaults(suiteName: suiteName)!
        return MappingStore(directory: directory, userDefaults: userDefaults)
    }
}
