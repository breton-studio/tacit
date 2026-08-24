import Foundation
import Testing
@testable import TacitCore

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TacitMappingStoreTests-\(UUID().uuidString)", isDirectory: true)
    return dir
}

/// A private `UserDefaults` suite, unique per call — mirrors `makeTempDirectory()`'s isolation
/// pattern so the workflow-defaults top-up flag (`MappingStore`'s injectable `userDefaults:`
/// parameter) never leaks state between tests or into a real `.standard` domain.
private func makeTempUserDefaults() -> UserDefaults {
    UserDefaults(suiteName: "TacitMappingStoreTests-flags-\(UUID().uuidString)")!
}

private let workflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

// MARK: - First launch defaults

@MainActor
@Test func firstLaunchHasTheSixWorkhorseUserBindingsEnabled() {
    let store = MappingStore(directory: makeTempDirectory())

    #expect(store.binding(for: .thumbIndexTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command]))))
    #expect(store.binding(for: .thumbMiddleTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command]))))
    #expect(store.binding(for: .victory) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control]))))
    #expect(store.binding(for: .thumbsUp) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: []))))
    #expect(store.binding(for: .thumbSwipeBackward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command]))))
    #expect(store.binding(for: .thumbSwipeForward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift]))))
}

/// M3 Task 11 (user requirement): app-switch, focus-input, and hold-to-dictate ship enabled on a
/// fresh install, no configuration needed.
@MainActor
@Test func firstLaunchHasTheWorkflowDefaultsTrioEnabled() {
    let store = MappingStore(directory: makeTempDirectory())

    #expect(store.binding(for: .swipeRight) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))) // ⌘Tab
    #expect(store.binding(for: .swipeUp) ==
        GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .indexPoint) ==
        GestureBinding(enabled: true, action: .holdKeystroke(KeyChord(keyCode: 63, modifiers: [])))) // Fn
}

@MainActor
@Test func firstLaunchReservedGesturesAreEnabledWithNilAction() {
    let store = MappingStore(directory: makeTempDirectory())
    #expect(store.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
    #expect(store.binding(for: .openPalm) == GestureBinding(enabled: true, action: nil))
}

@MainActor
@Test func firstLaunchOnlyTheNineUserBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .victory, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .swipeRight, .swipeUp, .indexPoint,
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
    let store = MappingStore(directory: makeTempDirectory())
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
    let store1 = MappingStore(directory: dir)
    let newBinding = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])))
    store1.setBinding(newBinding, for: .swipeLeft)

    let store2 = MappingStore(directory: dir)
    #expect(store2.binding(for: .swipeLeft) == newBinding)
}

@MainActor
@Test func setBindingOnUnboundGestureUsesSensibleDisabledDefault() {
    let store = MappingStore(directory: makeTempDirectory())
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

// MARK: - Workflow defaults one-time top-up (M3 Task 11)

/// Mirrors `MappingStore`'s own private `MappingsFile` v2 wire shape, keyed by raw `String`
/// (matching `V1MappingsFile` above's pattern) so a hand-built v2 fixture — an "existing user"
/// snapshot from before this task shipped — can be written directly to disk.
private struct V2MappingsFile: Codable {
    var version: Int
    var bindings: [String: GestureBinding]
}

@MainActor
@Test func topUpAppliesAllThreeDefaultsOnAFreshStoreWithNoExistingFile() {
    // A fresh install never wrote a mappings.json at all — `defaultBindings()` already has the
    // new enabled trio baked in, so the top-up is a no-op here, but it still needs to leave that
    // trio enabled (not accidentally revert them) and set the flag.
    let flags = makeTempUserDefaults()
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: flags)

    #expect(store.binding(for: .swipeRight).enabled == true)
    #expect(store.binding(for: .swipeUp).enabled == true)
    #expect(store.binding(for: .indexPoint).enabled == true)
    #expect(flags.bool(forKey: workflowDefaultsAppliedKey) == true)
}

/// The core top-up scenario: an existing user's `mappings.json` (written before this task) has
/// `swipeRight` deliberately customized — enabled, rebound to ⌃← — while `swipeUp` and
/// `indexPoint` still sit exactly on their old disabled suggested defaults, i.e. never touched.
/// Loading it for the first time under the new code must preserve the customized `swipeRight`
/// binding untouched, top up the other two to the new enabled defaults, and set the flag.
@MainActor
@Test func topUpKeepsACustomizedGestureAndToppsUpTheUntouchedOthers() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")

    let customizedSwipeRight = GestureBinding(
        enabled: true, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])) // user's own ⌃←
    )
    let oldSuggestedSwipeUp = GestureBinding(
        enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])) // pre-Task-11 ⌃↑
    )
    let oldSuggestedIndexPoint = GestureBinding(enabled: false, action: nil) // pre-Task-11: unbound

    let existingFile = V2MappingsFile(version: 2, bindings: [
        "swipeRight": customizedSwipeRight,
        "swipeUp": oldSuggestedSwipeUp,
        "indexPoint": oldSuggestedIndexPoint,
    ])
    try JSONEncoder().encode(existingFile).write(to: fileURL)

    let flags = makeTempUserDefaults()
    let store = MappingStore(directory: dir, userDefaults: flags)

    // The user's own binding survives exactly as they left it.
    #expect(store.binding(for: .swipeRight) == customizedSwipeRight)

    // The two untouched gestures are topped up to the new enabled defaults.
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .indexPoint) ==
        GestureBinding(enabled: true, action: .holdKeystroke(KeyChord(keyCode: 63, modifiers: []))))

    // The flag is set, and the topped-up bindings were actually persisted to disk.
    #expect(flags.bool(forKey: workflowDefaultsAppliedKey) == true)
    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.bindings["swipeRight"] == customizedSwipeRight)
    #expect(onDisk.bindings["swipeUp"] == GestureBinding(enabled: true, action: .focusTextInput))
}

/// Once the top-up has run (flag set), it must never run again — even if the user later disables
/// one of the topped-up gestures, a subsequent load must not silently re-enable it.
@MainActor
@Test func topUpNeverReappliesOnceTheFlagIsSet() {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()

    // First launch: fresh install, top-up runs (as a no-op, since defaults are already enabled)
    // and sets the flag.
    let store1 = MappingStore(directory: dir, userDefaults: flags)
    #expect(store1.binding(for: .swipeUp).enabled == true)

    // The user turns swipeUp back off.
    store1.setBinding(GestureBinding(enabled: false, action: .focusTextInput), for: .swipeUp)

    // A later load — flag already set — must leave that alone rather than re-topping it up.
    let store2 = MappingStore(directory: dir, userDefaults: flags)
    #expect(store2.binding(for: .swipeUp).enabled == false)
}

// MARK: - Reserved gestures are never bindable

@MainActor
@Test func setBindingOnReservedGestureIsANoOp() {
    let dir = makeTempDirectory()
    let store1 = MappingStore(directory: dir)
    let attempted = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])))
    store1.setBinding(attempted, for: .looseFist)
    #expect(store1.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))

    // Also confirm it didn't get persisted as a mutation.
    let store2 = MappingStore(directory: dir)
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

    let victoryBinding = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control])))
    let v1 = V1MappingsFile(version: 1, bindings: [
        "wristRotate": GestureBinding(enabled: true, action: nil),
        "victory": victoryBinding,
    ])
    try JSONEncoder().encode(v1).write(to: fileURL)

    let store = MappingStore(directory: dir)

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

    let store = MappingStore(directory: dir)
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

    let store = MappingStore(directory: dir)
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

    let store = MappingStore(directory: dir)
    #expect(store.bindings == MappingStore.defaultBindings())
}

/// Two successive corrupt-recoveries into the *same* directory must preserve BOTH quarantined
/// files — a collision on the quarantine name (e.g. two recoveries landing in the same directory)
/// must never delete a previously quarantined corrupt file to make room for a new one.
@MainActor
@Test func twoSuccessiveCorruptRecoveriesPreserveBothQuarantinedFiles() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")

    try Data("first corrupt payload".utf8).write(to: fileURL)
    _ = MappingStore(directory: dir)

    let firstQuarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(firstQuarantined.count == 1)

    try Data("second corrupt payload".utf8).write(to: fileURL)
    _ = MappingStore(directory: dir)

    let afterSecondRecovery = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("mappings.json.corrupt-") }
    #expect(afterSecondRecovery.count == 2, "both corrupt files must survive, got \(afterSecondRecovery)")

    // Both payloads must be independently recoverable — neither was overwritten by the other.
    let payloads = try afterSecondRecovery
        .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        .map { String(decoding: $0, as: UTF8.self) }
    #expect(Set(payloads) == ["first corrupt payload", "second corrupt payload"])
}
