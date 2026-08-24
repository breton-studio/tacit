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

    /// Backs the defaults-revision stamp (see `applyDefaultsRevisionsIfNeeded`) — which revision
    /// of `defaultBindings()` this install has been topped up to. Injectable the same way
    /// `directory` is: production code takes the default `.standard`, tests pass a private
    /// `UserDefaults(suiteName:)` so runs never share state with each other or with a real
    /// installation.
    private let userDefaults: UserDefaults

    /// - Parameters:
    ///   - directory: where `mappings.json` lives. Defaults to
    ///     `~/Library/Application Support/Tacit`; tests inject a temporary directory instead.
    ///   - userDefaults: backs the defaults-revision stamp (`defaultsRevisionKey`). Defaults to
    ///     `.standard`; tests inject a private suite.
    public init(directory: URL? = nil, userDefaults: UserDefaults = .standard) {
        let resolvedDirectory = directory ?? Self.defaultDirectory()
        self.directory = resolvedDirectory
        self.fileURL = resolvedDirectory.appendingPathComponent("mappings.json")
        self.userDefaults = userDefaults
        self.bindings = Self.defaultBindings()

        try? FileManager.default.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        let fileExisted = load()
        applyDefaultsRevisionsIfNeeded(fileExisted: fileExisted)
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
    ///
    /// - Returns: `true` if a `mappings.json` was present AND conveys real bindings history to
    ///   carry forward (readable v-current, or a v1 file successfully migrated); `false` on a
    ///   fresh install (no file) OR on the `recoverFromCorruption()` path. Threaded through to
    ///   `applyDefaultsRevisionsIfNeeded`, which uses it to decide whether to walk the revision
    ///   chain at all: a fresh install is already on `defaultBindings()`, and so — post-review fix
    ///   — is a corruption recovery, since `recoverFromCorruption()` resets `bindings` to
    ///   `Self.defaultBindings()` too (the current, fully-migrated values). Reporting `true` for
    ///   that branch used to make `applyDefaultsRevisionsIfNeeded` replay the ENTIRE revision
    ///   chain on top of bindings that were already final — currently harmless only by coincidence
    ///   (today's two revisions happen to round-trip back to `defaultBindings()`), but not
    ///   structurally guaranteed for a future revision. Treating a corrupt file as conveying no
    ///   history — same as a fresh install — makes recovery skip the walk entirely and just stamp
    ///   `currentDefaultsRevision`, which is correct: a quarantined file's prior state is gone, so
    ///   there is nothing to top up.
    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            persist()
            return false
        }
        if
            let decoded = try? JSONDecoder().decode(MappingsFile.self, from: data),
            decoded.version == Self.currentVersion
        {
            bindings = decoded.bindings
            return true
        }
        if
            let v1 = try? JSONDecoder().decode(MappingsFileV1.self, from: data),
            v1.version == 1
        {
            bindings = Self.migrateV1Bindings(v1.bindings)
            persist()
            return true
        }
        recoverFromCorruption()
        return false
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

    // MARK: - Defaults-revision chain

    /// One step of the defaults history. `changes[id].old` is what a NEVER-TOUCHED binding for
    /// `id` looked like before this revision; `new` is what it becomes. A binding is topped up only
    /// when it is EXACTLY equal to `old` — anything else is the user's own choice and is left alone.
    struct DefaultsRevision: Sendable {
        let revision: Int
        let changes: [GestureID: (old: GestureBinding, new: GestureBinding)]
    }

    /// The revision `defaultBindings()` currently represents. Bump it and append a
    /// `DefaultsRevision` whenever a default VALUE changes for existing users.
    public static let currentDefaultsRevision = 5

    /// `UserDefaults` key holding the revision an install has been topped up to (Int).
    static let defaultsRevisionKey = "tacit.defaultsRevision"
    /// The M3 Task 11 one-shot flag this chain replaces; still read so upgraded installs resume
    /// from revision 2 instead of replaying it.
    static let legacyWorkflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

    private static let fnChord = KeyChord(keyCode: 63, modifiers: [])

    static let defaultsRevisions: [DefaultsRevision] = [
        // M3 Task 11: app-switch, focus-input, hold-to-dictate — first shipped on the swipes.
        DefaultsRevision(revision: 2, changes: [
            .swipeRight: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
            ),
            .swipeUp: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .focusTextInput)
            ),
            .indexPoint: (
                old: GestureBinding(enabled: false, action: nil),
                new: GestureBinding(enabled: true, action: .holdKeystroke(fnChord))
            ),
        ]),
        // 2026-08-24 workhorse remap: the workflow trio moves onto static resting-hand poses,
        // the dynamic swipes go back to off, and a second workhorse toggles dictation.
        DefaultsRevision(revision: 3, changes: [
            .victory: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
            ),
            .thumbsUp: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: []))),
                new: GestureBinding(enabled: true, action: .focusTextInput)
            ),
            .swipeRight: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))),
                new: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])))
            ),
            .swipeUp: (
                old: GestureBinding(enabled: true, action: .focusTextInput),
                new: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])))
            ),
            .thumbRingPinkyTap: (
                old: GestureBinding(enabled: false, action: nil),
                new: GestureBinding(enabled: true, action: .toggleKeystroke(fnChord))
            ),
        ]),
        // 2026-08-24 product ruling ("flip through apps with one gesture, right/left, never
        // summon the app switcher"): swipeRight/swipeLeft take over app-switching directly via
        // `.switchApp` — never ⌘Tab, never the system switcher UI — so victory (which shipped rev
        // 3's ⌘Tab binding) is freed up and disabled with a ⌃Tab suggestion instead; there is no
        // more ⌘Tab anywhere in the defaults.
        DefaultsRevision(revision: 4, changes: [
            .swipeRight: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .switchApp(.next))
            ),
            .swipeLeft: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .switchApp(.previous))
            ),
            .victory: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))),
                new: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control])))
            ),
        ]),
        // 2026-08-24 ruling ("index-finger-up pose double-fires indexPoint AND
        // thumbRingPinkyTap — the thumb rests on the ring/pinky in that exact pose, so the two
        // gestures physically overlap"): a `.toggleKeystroke` bound to `thumbRingPinkyTap` can
        // never be told apart from `indexPoint`'s hold-to-dictate, so hands-free toggle moves
        // off it entirely, onto `victory` — a physically distinct pose that can't be confused
        // with a pointed index finger. `thumbRingPinkyTap` ships disabled with no suggested
        // action; `victory` picks up exactly the `.toggleKeystroke(Fn)` binding
        // `thumbRingPinkyTap` used to carry.
        DefaultsRevision(revision: 5, changes: [
            .victory: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .toggleKeystroke(fnChord))
            ),
            .thumbRingPinkyTap: (
                old: GestureBinding(enabled: true, action: .toggleKeystroke(fnChord)),
                new: GestureBinding(enabled: false, action: nil)
            ),
        ]),
    ]

    /// The revision this install was last topped up to: the Int key if present; else 2 if the
    /// legacy M3 bool flag is set; else 0.
    private var storedDefaultsRevision: Int {
        if userDefaults.object(forKey: Self.defaultsRevisionKey) != nil {
            return userDefaults.integer(forKey: Self.defaultsRevisionKey)
        }
        return userDefaults.bool(forKey: Self.legacyWorkflowDefaultsAppliedKey) ? 2 : 0
    }

    /// Walks every revision above `storedDefaultsRevision` in order, rewriting only bindings that
    /// still EXACTLY equal that revision's `old` value, then stamps `currentDefaultsRevision`.
    /// Runs at the end of `init`, after `load()` has settled `bindings`. A fresh install (`load()`
    /// returned `false` — no file existed) skips the walk entirely and just stamps, since
    /// `defaultBindings()` is already current; post-review fix — a corrupt-file recovery reports
    /// `fileExisted: false` for the same reason (`recoverFromCorruption()` also reset `bindings` to
    /// `defaultBindings()`, and a quarantined file conveys no history worth replaying a revision
    /// chain on top of).
    private func applyDefaultsRevisionsIfNeeded(fileExisted: Bool) {
        defer { userDefaults.set(Self.currentDefaultsRevision, forKey: Self.defaultsRevisionKey) }
        guard fileExisted else { return }
        let stored = storedDefaultsRevision
        guard stored < Self.currentDefaultsRevision else { return }

        var didChange = false
        for step in Self.defaultsRevisions where step.revision > stored {
            for (id, change) in step.changes where binding(for: id) == change.old {
                bindings[id] = change.new
                didChange = true
            }
        }
        if didChange {
            persist()
        }
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

    /// The factory bindings (spec §3.6, defaults revision 5 — the 2026-08-24 ring/pinky-tap-
    /// overlap ruling on top of the same-day app-switch ruling and workhorse remap): nine enabled
    /// user commands, the two reserved clutch/disarm gestures, and sensible-but-disabled
    /// suggestions (or `nil`, for continuous gestures with no discrete action yet) for everything
    /// else.
    public static func defaultBindings() -> [GestureID: GestureBinding] {
        var bindings: [GestureID: GestureBinding] = [:]

        // Enabled — the high-frequency workhorse core.
        bindings[.thumbIndexTap] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])) // ⌘C
        )
        bindings[.thumbMiddleTap] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command])) // ⌘V
        )
        bindings[.thumbSwipeBackward] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command])) // ⌘Z
        )
        bindings[.thumbSwipeForward] = GestureBinding(
            enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift])) // ⇧⌘Z
        )

        // Enabled — M3 Task 11's workflow trio, relocated onto workhorses by the 2026-08-24
        // remap: text-field focus (thumbsUp), hold-to-dictate (indexPoint). Toggle-dictate
        // (defaults revision 5) moved off `thumbRingPinkyTap` onto `victory` below — the
        // index-finger-up pose that fires `indexPoint` also fires `thumbRingPinkyTap` (the thumb
        // rests on the ring/pinky in that pose), so a toggle bound there could never be told
        // apart from indexPoint's hold. App-switching itself moved off victory/⌘Tab onto
        // swipeRight/swipeLeft below (defaults revision 4) — see those bindings' comments.
        bindings[.thumbsUp] = GestureBinding(enabled: true, action: .focusTextInput)
        bindings[.indexPoint] = GestureBinding(
            // Fn (keyCode 63) — Wispr Flow's stock hold-to-dictate hotkey.
            enabled: true, action: .holdKeystroke(KeyChord(keyCode: 63, modifiers: []))
        )
        // Toggle Fn — hands-free dictation. Defaults revision 5: moved here from
        // `thumbRingPinkyTap` (see the comment above) onto a pose that can't be confused with
        // indexPoint's hold-to-dictate. `TacitEngine.holdableGestures` routes this toggle through
        // the hold lifecycle (fires once per pose onset) rather than the repeat-firing plain
        // fire path, since `victory` is itself a holdable pose.
        bindings[.victory] = GestureBinding(
            enabled: true, action: .toggleKeystroke(KeyChord(keyCode: 63, modifiers: []))
        )

        // Reserved — always enabled, never bindable, no action (the system owns these).
        bindings[.looseFist] = GestureBinding(enabled: true, action: nil)
        bindings[.openPalm] = GestureBinding(enabled: true, action: nil)

        // Enabled — defaults revision 4 (2026-08-24, "flip through apps with one gesture,
        // right/left, never summon the app switcher"): a hand swipe right/left activates the
        // next/previous app DIRECTLY via `NSRunningApplication.activate` — never posts ⌘Tab,
        // never shows the system switcher.
        bindings[.swipeRight] = GestureBinding(enabled: true, action: .switchApp(.next))
        bindings[.swipeLeft] = GestureBinding(enabled: true, action: .switchApp(.previous))

        // Disabled, no suggested action — defaults revision 5: freed up by toggle-dictate's move
        // onto `victory` above (see that binding's comment for why the two poses overlapped).
        bindings[.thumbRingPinkyTap] = GestureBinding(enabled: false, action: nil)

        // Disabled, with a suggested action from the ergonomics report's mapping column.
        bindings[.swipeUp] = GestureBinding(
            enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])) // ⌃↑ suggestion
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
