import Foundation
import Testing
@testable import TacitCore

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TacitMappingStoreTests-\(UUID().uuidString)", isDirectory: true)
    return dir
}

/// A `UserDefaults` suite, unique per call, that removes its own persistent domain from
/// `~/Library/Preferences` when it is deallocated — mirrors `makeTempDirectory()`'s isolation
/// pattern so the workflow-defaults top-up flag (`MappingStore`'s injectable `userDefaults:`
/// parameter) never leaks state between tests or into a real `.standard` domain, AND doesn't
/// leak the on-disk domain itself.
///
/// Hygiene fix: before this, every call created a persistent `TacitMappingStoreTests-flags-<UUID>`
/// domain that was never removed — ~130 accumulated in `~/Library/Preferences` on the dev
/// machine (252 by the time this fix landed). `UserDefaults(suiteName:)` alone has no such
/// cleanup, so this subclasses it instead of returning a plain instance: `deinit` fires exactly
/// when the last strong reference goes away — a test's local `let flags = …`, and/or whichever
/// `MappingStore`(s) were constructed with it — which is always "when the test finishes," since
/// nothing outlives the `@Test` function. Subclassing (rather than a separate side-car wrapper
/// object a caller would have to keep alive via `defer`) means every existing call site, whether
/// bound to a local or passed inline as `userDefaults: makeTempUserDefaults()`, gets cleanup for
/// free with zero changes — the least invasive option, and paired-instance tests that share one
/// suite across two `MappingStore`s keep working unchanged (the shared `flags` local keeps the
/// suite alive across both).
///
/// `removePersistentDomain(forName:)` alone was verified (empirically, on this machine) to be
/// insufficient: it clears the domain's values and stops `defaults read`/cfprefsd from serving
/// it, but leaves an empty, `com.apple.quarantine`-tagged `.plist` file behind in
/// `~/Library/Preferences` — and `defaults domains` (unlike `defaults read`) enumerates that
/// directory's files directly, so the empty file still counts. Deleting the backing file
/// ourselves is what actually makes `defaults domains | grep -c TacitMappingStoreTests` go to 0.
private final class TempUserDefaultsSuite: UserDefaults {
    private let suiteName: String

    init(suiteName: String) {
        self.suiteName = suiteName
        super.init(suiteName: suiteName)!
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suiteName).plist")
        try? FileManager.default.removeItem(at: plistURL)
    }
}

private func makeTempUserDefaults() -> UserDefaults {
    TempUserDefaultsSuite(suiteName: "TacitMappingStoreTests-flags-\(UUID().uuidString)")
}

private let defaultsRevisionKey = "tacit.defaultsRevision"
private let legacyWorkflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

private let fn = KeyChord(keyCode: 63, modifiers: [])

// MARK: - First launch defaults (revision 3: workhorse remap)

@MainActor
@Test func firstLaunchHasTheWorkhorseCoreEnabledOnTheRevisionThreeDefaults() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())

    #expect(store.binding(for: .thumbIndexTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])))) // ⌘C
    #expect(store.binding(for: .thumbMiddleTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command])))) // ⌘V
    #expect(store.binding(for: .victory) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))) // ⌘Tab
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .thumbSwipeBackward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command])))) // ⌘Z
    #expect(store.binding(for: .thumbSwipeForward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift])))) // ⇧⌘Z
    #expect(store.binding(for: .indexPoint) == GestureBinding(enabled: true, action: .holdKeystroke(fn)))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

@MainActor
@Test func firstLaunchHasTheDynamicSwipesOffWithSuggestions() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .swipeRight) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])))) // ⌃→
    #expect(store.binding(for: .swipeUp) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])))) // ⌃↑
}

@MainActor
@Test func firstLaunchReservedGesturesAreEnabledWithNilAction() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
    #expect(store.binding(for: .openPalm) == GestureBinding(enabled: true, action: nil))
}

@MainActor
@Test func firstLaunchOnlyTheEightWorkhorseBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .victory, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .indexPoint, .thumbRingPinkyTap,
        .looseFist, .openPalm,
    ]
    #expect(enabledIDs == expected)
}

@MainActor
@Test func defaultBindingsCoverAllTwentyThreeGestureIDs() {
    let defaults = MappingStore.defaultBindings()
    #expect(Set(defaults.keys) == Set(GestureID.allCases))
}

@MainActor
@Test func rotateAndScrollSplitIDsHaveExpectedDisabledDefaults() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .twoFingerScrollUp) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: []))))
    #expect(store.binding(for: .twoFingerScrollDown) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 125, modifiers: []))))
    #expect(store.binding(for: .wristRotateCW) == GestureBinding(enabled: false, action: nil))
    #expect(store.binding(for: .wristRotateCCW) == GestureBinding(enabled: false, action: nil))
}

// MARK: - Persistence

@MainActor
@Test func setBindingPersistsAcrossASecondStoreInstance() {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()
    let store1 = MappingStore(directory: dir, userDefaults: flags)
    let newBinding = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])))
    store1.setBinding(newBinding, for: .swipeLeft)

    let store2 = MappingStore(directory: dir, userDefaults: flags)
    #expect(store2.binding(for: .swipeLeft) == newBinding)
}

@MainActor
@Test func setBindingOnUnboundGestureUsesSensibleDisabledDefault() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    let binding = store.binding(for: .wave)
    #expect(binding.enabled == false)
}

@Test func disabledConfiguredGestureStillPresentsItsAction() {
    let binding = GestureBinding(enabled: false, action: .runShortcut(name: "Focus"))

    #expect(binding.configuredActionSummary == "Shortcut: Focus")
}

@Test func enablingUnboundGestureRequestsActionConfiguration() {
    let binding = GestureBinding(enabled: false, action: nil)

    #expect(binding.enableRequest(true) == .configureAction)
}

@Test func enablingConfiguredGesturePreservesItsAction() {
    let action = TacitAction.openURL("superwhisper://record")
    let binding = GestureBinding(enabled: false, action: action)

    #expect(binding.enableRequest(true) == .update(GestureBinding(enabled: true, action: action)))
}

@Test func disablingGesturePreservesItsConfiguredAction() {
    let action = TacitAction.launchApp(bundleID: "com.apple.Safari", displayName: "Safari")
    let binding = GestureBinding(enabled: true, action: action)

    #expect(binding.enableRequest(false) == .update(GestureBinding(enabled: false, action: action)))
}

// MARK: - Defaults-revision chain

/// Mirrors `MappingStore`'s own private `MappingsFile` v2 wire shape, keyed by raw `String`
/// (matching `V1MappingsFile` above's pattern) so a hand-built v2 fixture — an "existing user"
/// snapshot from before this task shipped — can be written directly to disk.
private struct V2MappingsFile: Codable {
    var version: Int
    var bindings: [String: GestureBinding]
}

/// Encodes a v2 file the way a real install wrote it (keys are GestureID rawValues).
private func writeV2File(_ bindings: [String: GestureBinding], in dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("mappings.json")
    try JSONEncoder().encode(V2MappingsFile(version: 2, bindings: bindings)).write(to: url)
    return url
}

private let rev2Victory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control])))
private let rev2ThumbsUp = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: [])))
private let rev2SwipeRight = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
private let rev2SwipeUp = GestureBinding(enabled: true, action: .focusTextInput)
private let rev2RingPinky = GestureBinding(enabled: false, action: nil)

@MainActor
@Test func freshInstallStampsTheCurrentRevisionAndAppliesNoTopUp() {
    let flags = makeTempUserDefaults()
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: flags)
    #expect(flags.integer(forKey: defaultsRevisionKey) == MappingStore.currentDefaultsRevision)
    #expect(store.binding(for: .victory).action == .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
}

/// The core scenario for the user's own install: a rev-2 file (M3 top-up already applied, legacy
/// bool flag set) sitting exactly on the old defaults. Every changed gesture moves to rev 3.
@MainActor
@Test func untouchedRevisionTwoFileIsMovedToRevisionThree() throws {
    let dir = makeTempDirectory()
    let fileURL = try writeV2File([
        "victory": rev2Victory, "thumbsUp": rev2ThumbsUp,
        "swipeRight": rev2SwipeRight, "swipeUp": rev2SwipeUp,
        "thumbRingPinkyTap": rev2RingPinky,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))))
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))))
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 3)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.version == 2)
    #expect(onDisk.bindings["thumbRingPinkyTap"] == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

/// A customized binding — anything not EXACTLY equal to the old default — is left alone, while
/// its untouched neighbours still move.
@MainActor
@Test func customizedBindingsSurviveTheRevisionThreeTopUp() throws {
    let dir = makeTempDirectory()
    let usersVictory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command, .shift]))) // ⇧⌘Tab
    let usersDisabledThumbsUp = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 36, modifiers: []))) // turned off
    _ = try writeV2File([
        "victory": usersVictory, "thumbsUp": usersDisabledThumbsUp, "swipeRight": rev2SwipeRight,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == usersVictory)
    #expect(store.binding(for: .thumbsUp) == usersDisabledThumbsUp)
    #expect(store.binding(for: .swipeRight).enabled == false)
}

/// A pre-M3 file (no flag, no revision key) gets revision 2 THEN revision 3, in order: the
/// rev-2 top-up enables swipeRight→⌘Tab, and rev 3 then turns it back off — so the net result
/// equals a fresh rev-3 install for anything the user never touched.
@MainActor
@Test func preM3FileWalksTheWholeChainInOrder() throws {
    let dir = makeTempDirectory()
    _ = try writeV2File([
        "swipeRight": GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))),
        "swipeUp": GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))),
        "indexPoint": GestureBinding(enabled: false, action: nil),
        "victory": rev2Victory,
    ], in: dir)
    let flags = makeTempUserDefaults() // neither key set ⇒ revision 0

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .indexPoint) == GestureBinding(enabled: true, action: .holdKeystroke(fn)))
    #expect(store.binding(for: .swipeRight).enabled == false)
    #expect(store.binding(for: .swipeUp).enabled == false)
    #expect(store.binding(for: .victory).action == .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 3)
}

/// Once stamped at the current revision, a later load never re-applies — a user who turns the
/// toggle gesture off afterwards must not see it silently come back.
@MainActor
@Test func topUpNeverReappliesOnceStampedAtCurrentRevision() {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()
    let first = MappingStore(directory: dir, userDefaults: flags)
    first.setBinding(GestureBinding(enabled: false, action: .toggleKeystroke(fn)), for: .thumbRingPinkyTap)

    let second = MappingStore(directory: dir, userDefaults: flags)
    #expect(second.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: .toggleKeystroke(fn)))
}

// MARK: - Reserved gestures are never bindable

@MainActor
@Test func setBindingOnReservedGestureIsANoOp() {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()
    let store1 = MappingStore(directory: dir, userDefaults: flags)
    let attempted = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])))
    store1.setBinding(attempted, for: .looseFist)
    #expect(store1.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))

    // Also confirm it didn't get persisted as a mutation.
    let store2 = MappingStore(directory: dir, userDefaults: flags)
    #expect(store2.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
}

// MARK: - Schema v1 -> v2 migration

/// A hand-built v1 wire file: `bindings` keyed by raw `String` rather than `GestureID`, since a
/// real v1 file may contain `wristRotate`/`twoFingerScroll` keys that no longer exist as
/// `GestureID` cases. Mirrors `MappingStore`'s own private `MappingsFileV1` shape so the encoded
/// JSON is exactly what a real pre-migration `mappings.json` would contain.
private struct V1MappingsFile: Codable {
    var version: Int
    var bindings: [String: GestureBinding]
}

@MainActor
@Test func v1FileMigratesToV2DroppingRemovedKeysAndKeepingTheRest() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")

    // A deliberately customized chord (⌥⌘Tab) — NOT the rev-3 "old" value for `.victory`
    // (`enabled: true, .control`) — so this v1→v2 migration test stays decoupled from the
    // defaults-revision chain: it must only prove migration preserves the binding, not get
    // topped up to a newer default because it coincidentally matches an old one.
    let victoryBinding = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command, .option])))
    let v1 = V1MappingsFile(version: 1, bindings: [
        "wristRotate": GestureBinding(enabled: true, action: nil),
        "victory": victoryBinding,
    ])
    try JSONEncoder().encode(v1).write(to: fileURL)

    let store = MappingStore(directory: dir, userDefaults: makeTempUserDefaults())

    // The surviving binding carried forward intact.
    #expect(store.binding(for: .victory) == victoryBinding)

    // The removed ID's binding is gone; the new split IDs fall back to their disabled defaults,
    // not to whatever `wristRotate` used to be.
    #expect(store.binding(for: .wristRotateCW).enabled == false)
    #expect(store.binding(for: .wristRotateCCW).enabled == false)

    // Re-persisted on disk as version 2, with no wristRotate* key surviving.
    let onDisk = try JSONDecoder().decode(V1MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.version == 2)
    #expect(!onDisk.bindings.keys.contains { $0.hasPrefix("wristRotate") })
    #expect(onDisk.bindings["victory"] == victoryBinding)
}

// MARK: - Corruption recovery

@MainActor
@Test func corruptFileRecoversToDefaultsAndPreservesCorruptFile() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")
    try Data("not valid json at all { { {".utf8).write(to: fileURL)

    let store = MappingStore(directory: dir, userDefaults: makeTempUserDefaults())
    #expect(store.bindings == MappingStore.defaultBindings())

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let corruptFiles = contents.filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(corruptFiles.count == 1)
    // The corrupt file must retain the bad content, not be silently overwritten.
    if let name = corruptFiles.first {
        let preserved = try Data(contentsOf: dir.appendingPathComponent(name))
        #expect(String(decoding: preserved, as: UTF8.self) == "not valid json at all { { {")
    }
}

@MainActor
@Test func unknownVersionRecoversToDefaults() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")
    let futureFormat = "{\"version\": 99, \"bindings\": {}}"
    try Data(futureFormat.utf8).write(to: fileURL)

    let store = MappingStore(directory: dir, userDefaults: makeTempUserDefaults())
    #expect(store.bindings == MappingStore.defaultBindings())

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let corruptFiles = contents.filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(corruptFiles.count == 1)
}

@MainActor
@Test func recoveryNeverThrowsOrCrashesForGarbageBytes() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")
    try Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: fileURL)

    let store = MappingStore(directory: dir, userDefaults: makeTempUserDefaults())
    #expect(store.bindings == MappingStore.defaultBindings())
}

/// Post-review fix: a corruption recovery must count as a fresh install for the defaults-revision
/// chain, NOT as an existing file whose (already rev-3) `defaultBindings()` gets the ENTIRE
/// revision chain replayed on top of it. Seeds an existing-install signal (the legacy M3 bool
/// flag, i.e. "this install was previously topped up to revision 2") alongside a garbage
/// `mappings.json`, so if `load()` incorrectly reported `fileExisted: true` for the corruption
/// path, `applyDefaultsRevisionsIfNeeded` would walk revisions 2 AND 3 on top of the post-recovery
/// `defaultBindings()` — today's chain happens to round-trip back to the same values by
/// coincidence (see `final-review-general.md`), so this test's exact-equality assertion is the
/// only thing that would catch a REGRESSION of that coincidence, not the bug itself; the bug
/// itself is structural and is what the `load()`/`applyDefaultsRevisionsIfNeeded` fix addresses.
@MainActor
@Test func corruptFileRecoveryCountsAsFreshInstallNotAnExistingFileToTopUp() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")
    try Data("not valid json at all { { {".utf8).write(to: fileURL)

    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey) // "previously topped up to rev 2"

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.bindings == MappingStore.defaultBindings())
    #expect(flags.integer(forKey: defaultsRevisionKey) == MappingStore.currentDefaultsRevision)

    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let corruptFiles = contents.filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(corruptFiles.count == 1)
}

/// Two successive corrupt-recoveries into the *same* directory must preserve BOTH quarantined
/// files — a collision on the quarantine name (e.g. two recoveries landing in the same directory)
/// must never delete a previously quarantined corrupt file to make room for a new one.
@MainActor
@Test func twoSuccessiveCorruptRecoveriesPreserveBothQuarantinedFiles() throws {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")

    try Data("first corrupt payload".utf8).write(to: fileURL)
    _ = MappingStore(directory: dir, userDefaults: flags)

    let firstQuarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(firstQuarantined.count == 1)

    try Data("second corrupt payload".utf8).write(to: fileURL)
    _ = MappingStore(directory: dir, userDefaults: flags)

    let afterSecondRecovery = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(afterSecondRecovery.count == 2, "both corrupt files must survive, got \(afterSecondRecovery)")

    // Both payloads must be independently recoverable — neither was overwritten by the other.
    let payloads = try afterSecondRecovery
        .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        .map { String(decoding: $0, as: UTF8.self) }
    #expect(Set(payloads) == ["first corrupt payload", "second corrupt payload"])
}
