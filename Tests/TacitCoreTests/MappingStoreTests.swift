import Foundation
import Testing
@testable import TacitCore

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TacitMappingStoreTests-\(UUID().uuidString)", isDirectory: true)
    return dir
}

// MARK: - First launch defaults

@MainActor
@Test func firstLaunchHasExactlySixEnabledUserBindings() {
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

@MainActor
@Test func firstLaunchReservedGesturesAreEnabledWithNilAction() {
    let store = MappingStore(directory: makeTempDirectory())
    #expect(store.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
    #expect(store.binding(for: .openPalm) == GestureBinding(enabled: true, action: nil))
}

@MainActor
@Test func firstLaunchOnlyTheSixUserBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .victory, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .looseFist, .openPalm,
    ]
    #expect(enabledIDs == expected)
}

@MainActor
@Test func defaultBindingsCoverAllTwentyOneGestureIDs() {
    let defaults = MappingStore.defaultBindings()
    #expect(Set(defaults.keys) == Set(GestureID.allCases))
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
    let futureFormat = "{\"version\": 2, \"bindings\": {}}"
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
