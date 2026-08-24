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

// MARK: - First launch defaults (revision 6: 2026-08-24 "all four hand swipes switch apps"
// ruling on the ring/pinky-tap-overlap ruling, the app-switch ruling, and the workhorse remap)

@MainActor
@Test func firstLaunchHasTheWorkhorseCoreEnabledOnTheRevisionFiveDefaults() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())

    #expect(store.binding(for: .thumbIndexTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])))) // ⌘C
    #expect(store.binding(for: .thumbMiddleTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command])))) // ⌘V
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .thumbSwipeBackward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command])))) // ⌘Z
    #expect(store.binding(for: .thumbSwipeForward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift])))) // ⇧⌘Z
    #expect(store.binding(for: .indexPoint) == GestureBinding(enabled: true, action: .holdKeystroke(fn)))
    // Toggle-dictate moved off thumbRingPinkyTap (physically overlaps indexPoint's pose) onto
    // victory — see the rev-5 `DefaultsRevision` comment.
    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
}

/// 2026-08-24 product rulings: swipe right/left flip directly to the next/previous app (rev 4),
/// and swipe up/down join them (rev 6, "all four hand swipes move between apps in their
/// direction") — `.switchApp`, never ⌘Tab, never the system switcher. The app order is 1-D (the
/// ⌘Tab strip): right/down move forward, left/up move backward.
@MainActor
@Test func firstLaunchHasAllFourHandSwipesEnabledForAppSwitching() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeLeft) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(store.binding(for: .swipeDown) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .switchApp(.previous)))
}

/// Victory picks up toggle-dictation (defaults revision 5) — freed up by the app-switch move
/// (rev 4 left it disabled with a ⌃Tab suggestion), and a physically distinct pose from
/// indexPoint's hold-to-dictate, which is why the toggle moved here instead of staying on
/// thumbRingPinkyTap.
@MainActor
@Test func firstLaunchHasVictoryOnWithToggleDictation() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

/// thumbRingPinkyTap ships disabled with no suggested action (defaults revision 5) — its old
/// toggle-dictate binding moved to victory because the ring/pinky tap physically overlaps
/// indexPoint's hold-to-dictate pose (the thumb rests on the ring/pinky when the index finger is
/// pointed).
@MainActor
@Test func firstLaunchHasThumbRingPinkyTapOffWithNoAction() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
}

@MainActor
@Test func firstLaunchReservedGesturesAreEnabledWithNilAction() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .looseFist) == GestureBinding(enabled: true, action: nil))
    #expect(store.binding(for: .openPalm) == GestureBinding(enabled: true, action: nil))
}

@MainActor
@Test func firstLaunchOnlyTheElevenWorkhorseBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    // Defaults revision 5: victory (toggle-dictate) replaces thumbRingPinkyTap (now disabled) in
    // the enabled set. Defaults revision 6: swipeUp/swipeDown join swipeLeft/swipeRight as
    // enabled app-switch bindings ("all four hand swipes move between apps in their direction"),
    // bringing the total to eleven workhorse bindings plus the two reserved gestures (13).
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .indexPoint, .victory, .swipeLeft, .swipeRight, .swipeUp, .swipeDown,
        .looseFist, .openPalm,
    ]
    #expect(enabledIDs == expected)
    #expect(enabledIDs.count == 13)
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
    // Rev 5: victory carries toggle-dictate — app-switching stays on swipeRight/swipeLeft, and no
    // default anywhere posts ⌘Tab any more. Rev 6: swipeUp/swipeDown join them as direct
    // app-switch bindings too — all four hand swipes move between apps in their direction.
    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeLeft) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(store.binding(for: .swipeDown) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .switchApp(.previous)))
}

/// The core scenario for a rev-2 install (M3 top-up already applied, legacy bool flag set)
/// sitting exactly on the old defaults: it walks rev 3, rev 4, rev 5, AND rev 6 in one shot,
/// since a binding topped up by an earlier revision can immediately match the next revision's
/// `old` value too (rev 3 turns swipeRight/victory into exactly the values rev 4 expects as ITS
/// starting point, rev 3's `thumbRingPinkyTap` result is exactly rev 5's starting point too, and
/// rev 3's `swipeUp` result is exactly rev 6's starting point too) — the whole point of the chain
/// being applied in revision order on every load.
@MainActor
@Test func untouchedRevisionTwoFileWalksThroughRevisionThreeFourFiveAndSix() throws {
    let dir = makeTempDirectory()
    let fileURL = try writeV2File([
        "victory": rev2Victory, "thumbsUp": rev2ThumbsUp,
        "swipeRight": rev2SwipeRight, "swipeUp": rev2SwipeUp,
        "thumbRingPinkyTap": rev2RingPinky,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    // rev 3 alone would land victory on ⌘Tab; rev 4's `old` is exactly that ⌘Tab value, landing
    // it on the disabled ⌃Tab suggestion; rev 5's `old` is exactly THAT, so it keeps walking all
    // the way through to rev 5's enabled toggle-dictate default.
    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    // Same shape for swipeRight: rev 3 alone lands it on the disabled ⌃→ suggestion, but rev 4's
    // `old` is exactly that, so it keeps walking to the enabled `.switchApp(.next)` default; no
    // rev 5 entry for swipeRight, so it stops there.
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    // swipeUp: rev3 alone lands it on the disabled ⌃↑ suggestion (same shape it started with);
    // no rev4/rev5 entry for swipeUp, but that disabled ⌃↑ shape is exactly rev 6's `old`, so it
    // keeps walking to rev 6's enabled `.switchApp(.previous)` default.
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    // rev 3 alone would land thumbRingPinkyTap on the enabled toggle; rev 5's `old` is exactly
    // that value, so it keeps walking through to rev 5's disabled, no-action default.
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.version == 2)
    #expect(onDisk.bindings["thumbRingPinkyTap"] == GestureBinding(enabled: false, action: nil))
    #expect(onDisk.bindings["victory"] == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(onDisk.bindings["swipeUp"] == GestureBinding(enabled: true, action: .switchApp(.previous)))
}

/// A customized binding — anything not EXACTLY equal to the old default at whichever step it's
/// checked — is left alone at every step of the chain, while its untouched neighbours still move
/// all the way through to the current revision.
@MainActor
@Test func customizedBindingsSurviveTheRevisionChainTopUp() throws {
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
    // swipeRight was never customized, so it still walks the whole chain through to rev 4's
    // enabled `.switchApp(.next)` default — exactly like the untouched-file test above.
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
}

/// A pre-M3 file (no flag, no revision key) walks revisions 2, 3, 4, 5, AND 6 in order — the net
/// result equals a fresh rev-6 install for anything the user never touched, even though several
/// of these bindings pass through intermediate values along the way (e.g. swipeRight/victory/
/// swipeUp are each rewritten more than once before landing on their final rev-6 value).
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
    // swipeRight: rev2 old (disabled ⌃→) -> rev2 new (enabled ⌘Tab) -> matches rev3's old ->
    // rev3 new (disabled ⌃→, same shape it started with) -> matches rev4's old -> rev4 new
    // (enabled .switchApp(.next)); no rev5 entry for swipeRight, so it stops there.
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    // swipeUp: rev2 old (disabled ⌃↑) -> rev2 new (enabled .focusTextInput) -> matches rev3's old
    // -> rev3 new (disabled ⌃↑, same shape it started with); no rev4/rev5 entry for swipeUp, but
    // that disabled ⌃↑ shape matches rev6's old -> rev6 new (enabled .switchApp(.previous)).
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    // victory: untouched by rev2 (no entry there) -> matches rev3's old (⌃Tab) -> rev3 new
    // (⌘Tab) -> matches rev4's old -> rev4 new (disabled ⌃Tab) -> matches rev5's old -> rev5 new
    // (enabled toggle-dictate).
    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)
}

// MARK: - Defaults revision 4 (2026-08-24 app-switch ruling)

/// The realistic scenario for anyone who installed after the workhorse remap shipped: a file
/// already stamped at revision 3, sitting exactly on the rev-3 defaults. Rev 4's three changes
/// (swipeRight, swipeLeft, victory) apply, and — since victory's rev-4 result is exactly rev 5's
/// starting point — victory keeps walking straight through to rev 5's toggle-dictate default too;
/// everything else is untouched.
@MainActor
@Test func untouchedRevisionThreeFileMovesThroughRevisionFourAndFive() throws {
    let dir = makeTempDirectory()
    let rev3Victory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))) // ⌘Tab
    let rev3SwipeRight = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))) // ⌃→
    let rev3SwipeLeft = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control]))) // ⌃←
    let fileURL = try writeV2File([
        "victory": rev3Victory, "swipeRight": rev3SwipeRight, "swipeLeft": rev3SwipeLeft,
        "thumbsUp": rev2ThumbsUp, // deliberately NOT the rev3 result (.focusTextInput) — proves it's untouched
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(3, forKey: defaultsRevisionKey) // already fully topped up to rev 3

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeLeft) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    // Untouched by rev 4/5 (no entry) — stays exactly as the file had it, not the rev-3 topped-up value.
    #expect(store.binding(for: .thumbsUp) == rev2ThumbsUp)
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.bindings["swipeRight"] == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(onDisk.bindings["swipeLeft"] == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(onDisk.bindings["victory"] == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

/// A rev-3-stamped file with victory already customized — not exactly rev 4's (nor, transitively,
/// rev 5's) `old` value — keeps its customization all the way through, while its untouched
/// neighbours (swipeRight/swipeLeft) still move to rev 4.
@MainActor
@Test func customizedVictorySurvivesRevisionFourAndFiveTopUp() throws {
    let dir = makeTempDirectory()
    let usersVictory = GestureBinding(enabled: false, action: .runShortcut(name: "Switch Space")) // fully customized, off ⌘Tab entirely
    let rev3SwipeRight = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])))
    let rev3SwipeLeft = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 123, modifiers: [.control])))
    _ = try writeV2File([
        "victory": usersVictory, "swipeRight": rev3SwipeRight, "swipeLeft": rev3SwipeLeft,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(3, forKey: defaultsRevisionKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == usersVictory)
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .swipeLeft) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)
}

// MARK: - Defaults revision 5 (2026-08-24 ring/pinky-tap-overlap ruling)

/// The realistic scenario for anyone who installed after the app-switch ruling shipped: a file
/// already stamped at revision 4, sitting exactly on the rev-4 defaults. Only rev 5's two changes
/// (victory, thumbRingPinkyTap) apply; everything else is untouched.
@MainActor
@Test func untouchedRevisionFourFileMovesToRevisionFive() throws {
    let dir = makeTempDirectory()
    let rev4Victory = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control]))) // ⌃Tab
    let rev4ThumbRingPinky = GestureBinding(enabled: true, action: .toggleKeystroke(fn))
    let fileURL = try writeV2File([
        "victory": rev4Victory, "thumbRingPinkyTap": rev4ThumbRingPinky,
        "thumbsUp": rev2ThumbsUp, // deliberately NOT touched by rev 4 or rev 5 — proves it's untouched
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(4, forKey: defaultsRevisionKey) // already fully topped up to rev 4

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
    #expect(store.binding(for: .thumbsUp) == rev2ThumbsUp)
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.bindings["victory"] == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(onDisk.bindings["thumbRingPinkyTap"] == GestureBinding(enabled: false, action: nil))
}

/// A rev-4-stamped file with victory already customized — not exactly rev 5's `old` value — keeps
/// its customization, while its untouched neighbour (thumbRingPinkyTap) still moves to rev 5.
@MainActor
@Test func customizedVictorySurvivesRevisionFiveTopUp() throws {
    let dir = makeTempDirectory()
    let usersVictory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 49, modifiers: [.command]))) // ⌘Space, fully customized
    let rev4ThumbRingPinky = GestureBinding(enabled: true, action: .toggleKeystroke(fn))
    _ = try writeV2File([
        "victory": usersVictory, "thumbRingPinkyTap": rev4ThumbRingPinky,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(4, forKey: defaultsRevisionKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == usersVictory)
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: nil))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)
}

// MARK: - Defaults revision 6 (2026-08-24 "all four hand swipes switch apps" ruling)

/// The realistic scenario for anyone who installed after the ring/pinky-tap-overlap ruling
/// shipped: a file already stamped at revision 5, sitting exactly on the rev-5 defaults for
/// swipeUp and swipeDown. Rev 6's two changes apply to both, turning them into direct
/// `.switchApp` bindings — swipe up mirrors swipe left's `.previous`, swipe down mirrors swipe
/// right's `.next` — while everything else is untouched.
@MainActor
@Test func untouchedRevisionFiveFileMovesSwipeUpAndSwipeDownToRevisionSix() throws {
    let dir = makeTempDirectory()
    let rev5SwipeUp = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))) // ⌃↑
    let rev5SwipeDown = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 125, modifiers: [.control]))) // ⌃↓
    let fileURL = try writeV2File([
        "swipeUp": rev5SwipeUp, "swipeDown": rev5SwipeDown,
        "thumbsUp": rev2ThumbsUp, // deliberately NOT touched by rev 6 — proves it's untouched
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(5, forKey: defaultsRevisionKey) // already fully topped up to rev 5

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(store.binding(for: .swipeDown) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(store.binding(for: .thumbsUp) == rev2ThumbsUp)
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.bindings["swipeUp"] == GestureBinding(enabled: true, action: .switchApp(.previous)))
    #expect(onDisk.bindings["swipeDown"] == GestureBinding(enabled: true, action: .switchApp(.next)))
}

/// A rev-5-stamped file with swipeUp already customized — not exactly rev 6's `old` value — keeps
/// its customization, while its untouched neighbour (swipeDown) still moves to rev 6.
@MainActor
@Test func customizedSwipeUpSurvivesRevisionSixTopUpWhileSwipeDownMovesOn() throws {
    let dir = makeTempDirectory()
    let usersSwipeUp = GestureBinding(enabled: true, action: .runShortcut(name: "Mission Control")) // fully customized
    let rev5SwipeDown = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 125, modifiers: [.control]))) // ⌃↓
    _ = try writeV2File([
        "swipeUp": usersSwipeUp, "swipeDown": rev5SwipeDown,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(5, forKey: defaultsRevisionKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .swipeUp) == usersSwipeUp)
    #expect(store.binding(for: .swipeDown) == GestureBinding(enabled: true, action: .switchApp(.next)))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 6)
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
