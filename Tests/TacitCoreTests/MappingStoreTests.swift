import Foundation
import Testing
@testable import TacitCore

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TacitMappingStoreTests-\(UUID().uuidString)", isDirectory: true)
    return dir
}

// MARK: - First launch defaults

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

@Test func firstLaunchReservedGesturesAreEnabledWithNilAction() {
    let store = MappingStore(directory: makeTempDirectory())
    #expect(store.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
    #expect(store.binding(for: .openPalm) == GestureBinding(enabled: true, action: nil))
}

@Test func firstLaunchOnlyTheSixUserBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .victory, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .looseFist, .openPalm,
    ]
    #expect(enabledIDs == expected)
}

@Test func defaultBindingsCoverAllTwentyOneGestureIDs() {
    let defaults = MappingStore.defaultBindings()
    #expect(Set(defaults.keys) == Set(GestureID.allCases))
}

// MARK: - Persistence

@Test func setBindingPersistsAcrossASecondStoreInstance() {
    let dir = makeTempDirectory()
    let store1 = MappingStore(directory: dir)
    let newBinding = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])))
    store1.setBinding(newBinding, for: .swipeLeft)

    let store2 = MappingStore(directory: dir)
    #expect(store2.binding(for: .swipeLeft) == newBinding)
}

@Test func setBindingOnUnboundGestureUsesSensibleDisabledDefault() {
    let store = MappingStore(directory: makeTempDirectory())
    let binding = store.binding(for: .wave)
    #expect(binding.enabled == false)
}

// MARK: - Reserved gestures are never bindable

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

@Test func recoveryNeverThrowsOrCrashesForGarbageBytes() throws {
    let dir = makeTempDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent("mappings.json")
    try Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: fileURL)

    let store = MappingStore(directory: dir)
    #expect(store.bindings == MappingStore.defaultBindings())
}
