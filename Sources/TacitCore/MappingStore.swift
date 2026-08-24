import Foundation

/// Lets `[GestureID: _]` dictionaries encode/decode as a JSON object (keyed by `GestureID.rawValue`)
/// rather than a flat array of key/value pairs — the same trick `HandJoint` uses in `Models.swift`.
extension GestureID: CodingKeyRepresentable {}

/// Whether a gesture is currently wired to an action, and to what. `action == nil` means the
/// gesture has no action configured yet (a sensible disabled default, or a continuous gesture with
/// no discrete action to bind).
public struct GestureBinding: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var action: TacitAction?

    public init(enabled: Bool, action: TacitAction?) {
        self.enabled = enabled
        self.action = action
    }
}

/// The result of asking to change a gesture's enabled state. Enabling an unbound gesture cannot
/// produce useful behavior, so the UI redirects that intent into action configuration instead of
/// persisting an enabled no-op.
public enum GestureEnableRequest: Equatable, Sendable {
    case update(GestureBinding)
    case configureAction
}

public extension GestureBinding {
    /// The configured action is independent of whether recognition is currently enabled.
    var configuredActionSummary: String? { action?.summary }

    /// Resolves an enable-toggle interaction without discarding an existing action.
    func enableRequest(_ newValue: Bool) -> GestureEnableRequest {
        if newValue, action == nil {
            return .configureAction
        }

        var updated = self
        updated.enabled = newValue
        return .update(updated)
    }
}

/// The on-disk wire format for `mappings.json`. Versioned so a future incompatible change to
/// `TacitAction`'s Codable shape (see CARRY-FORWARD note on `TacitAction`) can be detected and
/// recovered from instead of crashing.
private struct MappingsFile: Codable {
    var version: Int
    var bindings: [GestureID: GestureBinding]
}

/// The version-1 wire format, kept around solely so `MappingStore.load` can migrate an old file
/// forward. `bindings` is keyed by raw `String` (not `GestureID`) because a v1 file may contain
/// keys — `wristRotate`, `twoFingerScroll` — that no longer exist as `GestureID` cases; decoding
/// straight into `[GestureID: GestureBinding]` would fail the whole file instead of just dropping
/// those two keys.
private struct MappingsFileV1: Codable {
    var version: Int
    var bindings: [String: GestureBinding]
}

/// The persistent store of user gesture→action bindings. Backed by `mappings.json` in an
/// application-support directory (injectable for tests). Never crashes on a corrupt or
/// future-versioned file — it quarantines the bad file and falls back to defaults.
///
/// `@MainActor`-isolated: only UI code (the specimen-book / mapping-editor surfaces) is expected to
/// read or write bindings, matching the convention `TacitEngine`/`FixtureRecorder` already use for
/// main-actor-owned, `@Published`-backed state in this codebase. This also means every file
/// operation `MappingStore` performs (`load`/`persist`/`recoverFromCorruption`) runs on the main
/// actor; that's acceptable here because these are small, local JSON reads/writes against a tiny
/// per-user file, not per-frame hot-path work.
@MainActor
public final class MappingStore: ObservableObject {
    /// The current `mappings.json` wire format version. Bump this — and add a migration path
    /// instead of just recovering to defaults — the day the wire format needs to change in a way
    /// that shouldn't discard user bindings.
    ///
    /// v2 (this version): `wristRotate` split into `wristRotateCW`/`wristRotateCCW`, and
    /// `twoFingerScroll` split into `twoFingerScrollUp`/`twoFingerScrollDown` — see
    /// `migrateV1Bindings`.
    public static let currentVersion = 2

    @Published public private(set) var bindings: [GestureID: GestureBinding]

    private let directory: URL
    private let fileURL: URL

    /// Where the one-time workflow-defaults top-up (see `applyWorkflowDefaultsTopUpIfNeeded`)
    /// records that it has already run. Injectable the same way `directory` is: production code
    /// takes the default `.standard`, tests pass a private `UserDefaults(suiteName:)` so runs
    /// never share state with each other or with a real installation.
    private let userDefaults: UserDefaults

    /// - Parameters:
    ///   - directory: where `mappings.json` lives. Defaults to
    ///     `~/Library/Application Support/Tacit`; tests inject a temporary directory instead.
    ///   - userDefaults: backs the one-time workflow-defaults top-up flag
    ///     (`workflowDefaultsAppliedKey`). Defaults to `.standard`; tests inject a private suite.
    public init(directory: URL? = nil, userDefaults: UserDefaults = .standard) {
        let resolvedDirectory = directory ?? Self.defaultDirectory()
        self.directory = resolvedDirectory
        self.fileURL = resolvedDirectory.appendingPathComponent("mappings.json")
        self.userDefaults = userDefaults
        self.bindings = Self.defaultBindings()

        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        load()
        applyWorkflowDefaultsTopUpIfNeeded()
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Tacit", isDirectory: true)
    }

    /// Reads `mappings.json` if present. A missing file just keeps (and persists) the in-memory
    /// defaults set in `init`. A v1 file is migrated forward and re-persisted as v2 (see
    /// `migrateV1Bindings`). A present-but-undecodable file, or one from a version this build
    /// doesn't otherwise understand, is quarantined via `recoverFromCorruption` and defaults take
    /// over — this never throws and never crashes.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            persist()
            return
        }
        if
            let decoded = try? JSONDecoder().decode(MappingsFile.self, from: data),
            decoded.version == Self.currentVersion
        {
            bindings = decoded.bindings
            return
        }
        if
            let v1 = try? JSONDecoder().decode(MappingsFileV1.self, from: data),
            v1.version == 1
        {
            bindings = Self.migrateV1Bindings(v1.bindings)
            persist()
            return
        }
        recoverFromCorruption()
    }

    /// Migrates a v1 `[String: GestureBinding]` map to v2: keys that no longer name a `GestureID`
    /// case — the removed `wristRotate` and `twoFingerScroll` — are dropped; everything else is
    /// carried forward under its (unchanged) `GestureID`. The new v2-only IDs
    /// (`wristRotateCW`/`CCW`, `twoFingerScrollUp`/`Down`) simply aren't present in the result,
    /// which is fine — `binding(for:)` already falls back to a disabled default for any missing
    /// key.
    private static func migrateV1Bindings(_ raw: [String: GestureBinding]) -> [GestureID: GestureBinding] {
        var migrated: [GestureID: GestureBinding] = [:]
        for (key, binding) in raw {
            guard let id = GestureID(rawValue: key) else { continue }
            migrated[id] = binding
        }
        return migrated
    }

    /// Renames the unreadable/unrecognized file to `mappings.json.corrupt-<timestamp>` — preserving
    /// it for later inspection rather than silently overwriting it — then resets to defaults and
    /// persists a fresh, valid file in its place.
    ///
    /// The quarantine name is collision-safe: if a file already exists at the timestamped name
    /// (e.g. two recoveries land in the same directory within the same microsecond, or a prior
    /// quarantined file was never cleaned up), an incrementing `-2`, `-3`, … suffix is appended
    /// until a free name is found. This never deletes an existing quarantined file to make room.
    private func recoverFromCorruption() {
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        var quarantineURL = directory.appendingPathComponent("mappings.json.corrupt-\(timestamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: quarantineURL.path) {
            quarantineURL = directory.appendingPathComponent("mappings.json.corrupt-\(timestamp)-\(suffix)")
            suffix += 1
        }
        try? FileManager.default.moveItem(at: fileURL, to: quarantineURL)

        bindings = Self.defaultBindings()
        persist()
    }

    /// UserDefaults key marking that the M3 Task 11 workflow-defaults top-up (below) has already
    /// run for this install. Deliberately independent of `mappings.json`'s own `version` — this
    /// is about which *default values* got applied on top of an existing file, not about the wire
    /// format, so it lives in `UserDefaults` (via the injectable `userDefaults`) rather than in
    /// the mappings file itself.
    private static let workflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

    /// The three gestures the M3 Task 11 top-up applies new enabled defaults to. Order matches
    /// where they're introduced in `defaultBindings()`.
    private static let workflowDefaultTopUpIDs: [GestureID] = [.swipeRight, .swipeUp, .indexPoint]

    /// What each of `workflowDefaultTopUpIDs` suggested — disabled — *before* this task. A
    /// pre-Task-11 install's `mappings.json` shows exactly this for one of these gestures if the
    /// user never touched it. This table exists solely so `applyWorkflowDefaultsTopUpIfNeeded`
    /// can tell "still on the old suggestion" apart from "user rebound this while it was
    /// disabled" — `defaultBindings()` above already reflects the NEW (enabled) defaults, not
    /// these.
    private static let oldSuggestedDefaultActions: [GestureID: TacitAction?] = [
        .swipeRight: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])), // ⌃→
        .swipeUp: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])), // ⌃↑ Mission Control
        .indexPoint: nil, // no discrete keystroke suggested pre-Task-11
    ]

    /// One-time top-up for EXISTING users (M3 Task 11, user requirement): applies the new enabled
    /// workflow defaults — app-switch (`swipeRight`), focus-input (`swipeUp`), and hold-to-dictate
    /// (`indexPoint`) — to any of those three gestures the user never customized, then marks the
    /// top-up done via `userDefaults` so it never runs again. Runs unconditionally at the end of
    /// `init`, after `load()` has settled `bindings` (fresh defaults, a migrated v1 file, a
    /// corruption-recovered default set, or a normal v2 load all land here the same way).
    ///
    /// A fresh install is a no-op here: `defaultBindings()` already enables all three, so every
    /// one of them reads as "customized" below (because `enabled` is already `true`) — nothing to
    /// top up, just the flag gets set. The top-up only changes behavior for an existing
    /// `mappings.json` written before this task shipped.
    ///
    /// **"Customized" predicate** (meaning: leave this gesture alone) for a given gesture's
    /// current binding — either of:
    ///   - `enabled == true` — the user has this gesture live at all, even if it happens to still
    ///     point at the exact old suggested action; turning it on is itself a deliberate choice.
    ///   - `action` differs from that gesture's entry in `oldSuggestedDefaultActions` — the user
    ///     rebound it to something else (or cleared it) while it was still disabled.
    ///
    /// Anything else — disabled, and sitting on exactly the old suggested (or, for `indexPoint`,
    /// the old `nil`) action — is the "never touched this" state, and gets replaced with the new
    /// enabled default from `defaultBindings()`.
    private func applyWorkflowDefaultsTopUpIfNeeded() {
        guard !userDefaults.bool(forKey: Self.workflowDefaultsAppliedKey) else { return }

        let newDefaults = Self.defaultBindings()
        var didChange = false
        for id in Self.workflowDefaultTopUpIDs {
            let current = binding(for: id)
            let oldSuggestedAction = Self.oldSuggestedDefaultActions[id] ?? nil
            let isCustomized = current.enabled || current.action != oldSuggestedAction
            guard !isCustomized, let newDefault = newDefaults[id] else { continue }
            bindings[id] = newDefault
            didChange = true
        }

        if didChange {
            persist()
        }
        userDefaults.set(true, forKey: Self.workflowDefaultsAppliedKey)
    }

    /// The binding for `id`, or a sensible disabled default (no action) if none is stored yet.
    public func binding(for id: GestureID) -> GestureBinding {
        bindings[id] ?? GestureBinding(enabled: false, action: nil)
    }

    /// Updates the binding for `id` and persists immediately. A no-op for reserved gestures
    /// (`looseFist`, `openPalm`) — those are never user-bindable, so the store silently ignores the
    /// request rather than letting the clutch/disarm gesture be reassigned or disabled.
    public func setBinding(_ binding: GestureBinding, for id: GestureID) {
        guard !GestureCatalog.entry(for: id).isReserved else { return }
        bindings[id] = binding
        persist()
    }

    private func persist() {
        let file = MappingsFile(version: Self.currentVersion, bindings: bindings)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The factory bindings (spec §3.6, plus M3 Task 11's workflow trio): nine enabled user
    /// commands, the two reserved clutch/disarm gestures, and sensible-but-disabled suggestions
    /// (or `nil`, for continuous gestures with no discrete action yet) for everything else.
    public static func defaultBindings() -> [GestureID: GestureBinding] {
        var bindings: [GestureID: GestureBinding] = [:]

        // Enabled — the high-frequency workhorse core.
        bindings[.thumbIndexTap] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])) // ⌘C
        )
        bindings[.thumbMiddleTap] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command])) // ⌘V
        )
        bindings[.victory] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control])) // ⌃Tab
        )
        bindings[.thumbsUp] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: [])) // Return
        )
        bindings[.thumbSwipeBackward] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command])) // ⌘Z
        )
        bindings[.thumbSwipeForward] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift])) // ⇧⌘Z
        )

        // Enabled — M3 Task 11's workflow defaults (user requirement): everyday app-switching,
        // text-field focus, and hold-to-dictate, ready to use on a fresh install without any
        // configuration. See `workflowDefaultTopUpIDs`/`oldSuggestedDefaultActions` below for how
        // existing users get these applied too, without disturbing anything they've customized.
        bindings[.swipeRight] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])) // ⌘Tab
        )
        bindings[.swipeUp] = GestureBinding(enabled: true, action: .focusTextInput)
        bindings[.indexPoint] = GestureBinding(
            // Fn (keyCode 63) — Wispr Flow's stock hold-to-dictate hotkey.
            enabled: true, action: .holdKeystroke(KeyChord(keyCode: 63, modifiers: []))
        )

        // Reserved — always enabled, never bindable, no action (the system owns these).
        bindings[.looseFist] = GestureBinding(enabled: true, action: nil)
        bindings[.openPalm] = GestureBinding(enabled: true, action: nil)

        // Disabled, with a suggested action from the ergonomics report's mapping column.
        bindings[.thumbRingPinkyTap] = GestureBinding(enabled: false, action: nil) // rarer command, undecided
        bindings[.swipeLeft] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])) // ⌃←
        )
        bindings[.swipeDown] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 125, modifiers: [.control])) // ⌃↓ App Exposé
        )
        bindings[.fistToOpen] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 13, modifiers: [.command])) // ⌘W
        )
        // Continuous gestures — not bindable to a single discrete action yet.
        bindings[.pinchDrag] = GestureBinding(enabled: false, action: nil)
        // No sensible keystroke default for a rotary tick — the catalog editorial explains the
        // repeat-tick behavior instead.
        bindings[.wristRotateCW] = GestureBinding(enabled: false, action: nil)
        bindings[.wristRotateCCW] = GestureBinding(enabled: false, action: nil)
        bindings[.twoFingerScrollUp] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [])) // Up arrow
        )
        bindings[.twoFingerScrollDown] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 125, modifiers: [])) // Down arrow
        )
        bindings[.palmPush] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 49, modifiers: [])) // Space, play/pause proxy
        )
        bindings[.wave] = GestureBinding(enabled: false, action: nil)
        bindings[.twoHandFrame] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 21, modifiers: [.command, .shift])) // ⇧⌘4
        )

        return bindings
    }
}
