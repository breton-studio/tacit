import Foundation
import Testing
@testable import TacitCore

// MARK: - TacitAction

@Test func requiresAccessibilityIsTrueOnlyForKeystrokeHoldKeystrokeAndFocusTextInput() {
    #expect(TacitAction.keystroke(KeyChord(keyCode: 8, modifiers: [.command])).requiresAccessibility == true)
    #expect(TacitAction.holdKeystroke(KeyChord(keyCode: 63, modifiers: [])).requiresAccessibility == true)
    #expect(TacitAction.toggleKeystroke(KeyChord(keyCode: 63, modifiers: [])).requiresAccessibility == true)
    #expect(TacitAction.focusTextInput.requiresAccessibility == true)
    #expect(TacitAction.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").requiresAccessibility == false)
    #expect(TacitAction.openURL("superwhisper://record").requiresAccessibility == false)
    #expect(TacitAction.runShortcut(name: "Focus").requiresAccessibility == false)
    #expect(TacitAction.switchApp(.next).requiresAccessibility == false)
    #expect(TacitAction.switchApp(.previous).requiresAccessibility == false)
}

@Test func summaryDescribesEachAction() {
    #expect(TacitAction.keystroke(KeyChord(keyCode: 8, modifiers: [.command])).summary == "⌘C")
    #expect(TacitAction.holdKeystroke(KeyChord(keyCode: 49, modifiers: [.command])).summary == "Hold ⌘Space")
    #expect(TacitAction.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").summary == "Open Ghostty")
    #expect(TacitAction.openURL("superwhisper://record").summary == "superwhisper://record")
    #expect(TacitAction.runShortcut(name: "Focus").summary == "Shortcut: Focus")
    #expect(TacitAction.focusTextInput.summary == "Focus text input")
    #expect(TacitAction.switchApp(.next).summary == "Next app")
    #expect(TacitAction.switchApp(.previous).summary == "Previous app")
}

/// M3 Task 11 (fix pass): renamed from `holdKeystrokeSummarySpecialCasesFnKeyCode63` — there's no
/// special case anymore. `KeyChord.capNames` maps keyCode 63 to "Fn", so this is just plain
/// `"Hold " + chord.display` doing its normal thing.
@Test func holdKeystrokeSummaryRendersFnViaDisplay() {
    #expect(TacitAction.holdKeystroke(KeyChord(keyCode: 63, modifiers: [])).summary == "Hold Fn")
}

// MARK: - toggleKeystroke (workhorse-remap plan, Task 1)

@Test func toggleKeystrokeRequiresAccessibility() {
    #expect(TacitAction.toggleKeystroke(KeyChord(keyCode: 63, modifiers: [])).requiresAccessibility == true)
}

@Test func toggleKeystrokeSummaryRendersToggleFnViaDisplay() {
    #expect(TacitAction.toggleKeystroke(KeyChord(keyCode: 63, modifiers: [])).summary == "Toggle Fn")
    #expect(TacitAction.toggleKeystroke(KeyChord(keyCode: 49, modifiers: [.command])).summary == "Toggle ⌘Space")
}

@Test func toggleKeystrokeCodableRoundTrips() throws {
    let action = TacitAction.toggleKeystroke(KeyChord(keyCode: 63, modifiers: []))
    let data = try JSONEncoder().encode(action)
    #expect(try JSONDecoder().decode(TacitAction.self, from: data) == action)
}

@Test func tacitActionCodableRoundTrips() throws {
    let actions: [TacitAction] = [
        .keystroke(KeyChord(keyCode: 8, modifiers: [.command])),
        .holdKeystroke(KeyChord(keyCode: 63, modifiers: [])),
        .launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .openURL("superwhisper://record"),
        .runShortcut(name: "Focus"),
        .focusTextInput,
        .toggleKeystroke(KeyChord(keyCode: 63, modifiers: [])),
        .switchApp(.next),
        .switchApp(.previous),
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(TacitAction.self, from: data)
        #expect(decoded == action)
    }
}

/// M3 Task 9/10: an old (pre-`.holdKeystroke`/`.focusTextInput`) encoded `.keystroke` payload must
/// still decode fine — adding a new enum case to a synthesized-Codable enum never perturbs
/// decoding of payloads from cases that already existed.
@Test func oldKeystrokePayloadStillDecodesAfterHoldKeystrokeWasAdded() throws {
    let original = TacitAction.keystroke(KeyChord(keyCode: 8, modifiers: [.command]))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TacitAction.self, from: data)
    #expect(decoded == original)
}

// MARK: - ActionDispatcher

/// A spy environment that records which closures were invoked and lets each call succeed or
/// fail on demand. Code review 2026-08-27, Finding 4 / item (e): `dispatch(_:)` is `async` now,
/// but every call below is still `await`ed sequentially, one at a time, within a single test —
/// nothing here ever runs two closure calls concurrently against the same `Spy` instance — so the
/// unchecked Sendable conformance remains safe on the same basis it always was.
private final class Spy: @unchecked Sendable {
    var postKeystrokeCalls: [KeyChord] = []
    /// Every `postKeyDown`/`postKeyUp` call, in order, tagged by direction — a single merged log
    /// (rather than two separate arrays) so tests can assert ORDERING (down strictly before up)
    /// as well as which chord each call carried.
    var keyDirectionCalls: [(direction: String, chord: KeyChord)] = []
    var launchAppCalls: [String] = []
    var openURLCalls: [String] = []
    var runShortcutCalls: [String] = []
    var focusTextInputCallCount = 0
    var switchAppCalls: [AppSwitchDirection] = []
    var isAccessibilityTrustedCallCount = 0

    var postKeystrokeResult = true
    var postKeyDownResult = true
    var postKeyUpResult = true
    var launchAppResult = true
    var openURLResult = true
    var runShortcutResult = true
    var focusTextInputResult = true
    var switchAppResult = true
    var isAccessibilityTrustedResult = true

    var postKeyDownCalls: [KeyChord] { keyDirectionCalls.filter { $0.direction == "down" }.map(\.chord) }
    var postKeyUpCalls: [KeyChord] { keyDirectionCalls.filter { $0.direction == "up" }.map(\.chord) }
}

private func makeDispatcher(_ spy: Spy) -> ActionDispatcher {
    ActionDispatcher(environment: ActionEnvironment(
        postKeystroke: { chord in spy.postKeystrokeCalls.append(chord); return spy.postKeystrokeResult },
        postKeyDown: { chord in spy.keyDirectionCalls.append((direction: "down", chord: chord)); return spy.postKeyDownResult },
        postKeyUp: { chord in spy.keyDirectionCalls.append((direction: "up", chord: chord)); return spy.postKeyUpResult },
        launchApp: { bundleID in spy.launchAppCalls.append(bundleID); return spy.launchAppResult },
        openURL: { string in spy.openURLCalls.append(string); return spy.openURLResult },
        runShortcut: { name in spy.runShortcutCalls.append(name); return spy.runShortcutResult },
        focusTextInput: { spy.focusTextInputCallCount += 1; return spy.focusTextInputResult },
        switchApp: { direction in spy.switchAppCalls.append(direction); return spy.switchAppResult },
        isAccessibilityTrusted: { spy.isAccessibilityTrustedCallCount += 1; return spy.isAccessibilityTrustedResult }
    ))
}

@Test func dispatchKeystrokeCallsPostKeystrokeWhenTrusted() async {
    let spy = Spy()
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = await makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .performed)
    #expect(spy.postKeystrokeCalls == [chord])
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
}

@Test func dispatchKeystrokeReturnsNeedsAccessibilityWithoutPostingWhenUntrusted() async {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = await makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .needsAccessibility)
    #expect(spy.postKeystrokeCalls.isEmpty)
}

@Test func dispatchKeystrokeFailsWithSummaryInMessage() async {
    let spy = Spy()
    spy.postKeystrokeResult = false
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = await makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .failed("Couldn't press ⌘C"))
}

@Test func dispatchLaunchAppCallsExactlyLaunchApp() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"))
    #expect(outcome == .performed)
    #expect(spy.launchAppCalls == ["com.mitchellh.ghostty"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchLaunchAppFailsWithDisplayNameInMessage() async {
    let spy = Spy()
    spy.launchAppResult = false
    let outcome = await makeDispatcher(spy).dispatch(.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"))
    #expect(outcome == .failed("Couldn't open Ghostty"))
}

@Test func dispatchOpenURLCallsExactlyOpenURL() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.openURL("superwhisper://record"))
    #expect(outcome == .performed)
    #expect(spy.openURLCalls == ["superwhisper://record"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchOpenURLFailsWithURLInMessage() async {
    let spy = Spy()
    spy.openURLResult = false
    let outcome = await makeDispatcher(spy).dispatch(.openURL("superwhisper://record"))
    #expect(outcome == .failed("Couldn't open superwhisper://record"))
}

@Test func dispatchRunShortcutCallsExactlyRunShortcut() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.runShortcut(name: "Focus"))
    #expect(outcome == .performed)
    #expect(spy.runShortcutCalls == ["Focus"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchRunShortcutFailsWithNameInMessage() async {
    let spy = Spy()
    spy.runShortcutResult = false
    let outcome = await makeDispatcher(spy).dispatch(.runShortcut(name: "Focus"))
    #expect(outcome == .failed("Couldn't run Shortcut 'Focus'"))
}

// MARK: - .holdKeystroke's normal-fire-path fallback (M3 Task 9)

/// A `.holdKeystroke` dispatched through the NORMAL fire path (i.e. `TacitEngine.handleFire`, for
/// a momentary gesture with no `HoldTracker` hold behind it — see `ActionDispatcher.dispatch`'s
/// `.holdKeystroke` case doc comment) must perform a full press: both halves, down and up.
@Test func dispatchHoldKeystrokeCallsPostKeyDownAndPostKeyUpWhenTrusted() async {
    let spy = Spy()
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.holdKeystroke(chord))
    #expect(outcome == .performed)
    #expect(spy.postKeyDownCalls == [chord])
    #expect(spy.postKeyUpCalls == [chord])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
}

/// Ordering matters: the key-down MUST be posted before the key-up (a full press with the halves
/// reversed is nonsensical and could confuse a listening app).
@Test func dispatchHoldKeystrokeFullPressPostsDownBeforeUp() async {
    let spy = Spy()
    let chord = KeyChord(keyCode: 63, modifiers: [])
    _ = await makeDispatcher(spy).dispatch(.holdKeystroke(chord))
    #expect(spy.keyDirectionCalls.map(\.direction) == ["down", "up"])
}

@Test func dispatchHoldKeystrokeReturnsNeedsAccessibilityWithoutPostingWhenUntrusted() async {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.holdKeystroke(chord))
    #expect(outcome == .needsAccessibility)
    #expect(spy.keyDirectionCalls.isEmpty)
}

@Test func dispatchHoldKeystrokeFailsWhenPostKeyDownFails() async {
    let spy = Spy()
    spy.postKeyDownResult = false
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.holdKeystroke(chord))
    // M3 Task 11: keyCode 63 now has a cap name ("Fn") in `KeyChord.capNames`, so the failure
    // message reads the key's name rather than its raw hex code.
    #expect(outcome == .failed("Couldn't press Fn"))
    // The up half is never attempted once the down half itself failed.
    #expect(spy.postKeyUpCalls.isEmpty)
}

@Test func dispatchHoldKeystrokeFailsWhenPostKeyUpFails() async {
    let spy = Spy()
    spy.postKeyUpResult = false
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.holdKeystroke(chord))
    #expect(outcome == .failed("Couldn't press Fn"))
    #expect(spy.postKeyDownCalls == [chord])
}

// MARK: - .toggleKeystroke's normal-fire-path fallback (workhorse-remap plan, Task 1)

/// A `.toggleKeystroke` dispatched through the NORMAL fire path (i.e. a non-engine caller with no
/// `KeyLatch` behind it) must perform a full press: both halves, down and up. Same fallback shape
/// as `.holdKeystroke` above.
@Test func dispatchToggleKeystrokeCallsPostKeyDownAndPostKeyUpWhenTrusted() async {
    let spy = Spy()
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.toggleKeystroke(chord))
    #expect(outcome == .performed)
    #expect(spy.postKeyDownCalls == [chord])
    #expect(spy.postKeyUpCalls == [chord])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
}

/// Ordering matters: the key-down MUST be posted before the key-up (a full press with the halves
/// reversed is nonsensical and could confuse a listening app).
@Test func dispatchToggleKeystrokeFullPressPostsDownBeforeUp() async {
    let spy = Spy()
    let chord = KeyChord(keyCode: 63, modifiers: [])
    _ = await makeDispatcher(spy).dispatch(.toggleKeystroke(chord))
    #expect(spy.keyDirectionCalls.map(\.direction) == ["down", "up"])
}

@Test func dispatchToggleKeystrokeReturnsNeedsAccessibilityWithoutPostingWhenUntrusted() async {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.toggleKeystroke(chord))
    #expect(outcome == .needsAccessibility)
    #expect(spy.keyDirectionCalls.isEmpty)
}

@Test func dispatchToggleKeystrokeFailsWhenPostKeyDownFails() async {
    let spy = Spy()
    spy.postKeyDownResult = false
    let chord = KeyChord(keyCode: 63, modifiers: [])
    let outcome = await makeDispatcher(spy).dispatch(.toggleKeystroke(chord))
    // keyCode 63 has a cap name ("Fn") in `KeyChord.capNames`, so the failure message reads the
    // key's name rather than its raw hex code.
    #expect(outcome == .failed("Couldn't press Fn"))
    // The up half is never attempted once the down half itself failed.
    #expect(spy.postKeyUpCalls.isEmpty)
}

// MARK: - .focusTextInput (M3 Task 10)

@Test func dispatchFocusTextInputCallsExactlyFocusTextInputWhenTrusted() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.focusTextInput)
    #expect(outcome == .performed)
    #expect(spy.focusTextInputCallCount == 1)
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.keyDirectionCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
}

/// `.focusTextInput.requiresAccessibility == true`, so this must go through the same gate as
/// `.keystroke`/`.holdKeystroke` — untrusted means the closure is never even called.
@Test func dispatchFocusTextInputReturnsNeedsAccessibilityWithoutCallingWhenUntrusted() async {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let outcome = await makeDispatcher(spy).dispatch(.focusTextInput)
    #expect(outcome == .needsAccessibility)
    #expect(spy.focusTextInputCallCount == 0)
}

@Test func dispatchFocusTextInputFailsWithFixedMessageWhenClosureReturnsFalse() async {
    let spy = Spy()
    spy.focusTextInputResult = false
    let outcome = await makeDispatcher(spy).dispatch(.focusTextInput)
    #expect(outcome == .failed("Couldn't find a text field."))
}

// MARK: - .switchApp (2026-08-24 product ruling)

@Test func dispatchSwitchAppNextCallsExactlySwitchAppWithNext() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.switchApp(.next))
    #expect(outcome == .performed)
    #expect(spy.switchAppCalls == [.next])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.focusTextInputCallCount == 0)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchSwitchAppPreviousCallsExactlySwitchAppWithPrevious() async {
    let spy = Spy()
    let outcome = await makeDispatcher(spy).dispatch(.switchApp(.previous))
    #expect(outcome == .performed)
    #expect(spy.switchAppCalls == [.previous])
}

@Test func dispatchSwitchAppFailsWithFixedMessageWhenClosureReturnsFalse() async {
    let spy = Spy()
    spy.switchAppResult = false
    let outcome = await makeDispatcher(spy).dispatch(.switchApp(.next))
    #expect(outcome == .failed("Couldn't switch app"))
}

@Test func dispatchSwitchAppNeverGatedByAccessibility() async {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let outcome = await makeDispatcher(spy).dispatch(.switchApp(.next))
    #expect(outcome == .performed)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

/// The dispatcher's Accessibility gate is derived from `TacitAction.requiresAccessibility`
/// generically (not re-implemented per case) — this is the invariant that guarantees any FUTURE
/// action with `requiresAccessibility == true` is automatically covered without anyone having to
/// remember to add a matching guard in `dispatch(_:)`. `.focusTextInput` exercises that here: it
/// gets the gate despite never touching `postKeystroke`/`postKeyDown`/`postKeyUp`.
@Test func accessibilityGateAppliesToEveryRequiresAccessibilityAction() async {
    let requiresAccessibilityActions: [TacitAction] = [
        .keystroke(KeyChord(keyCode: 8, modifiers: [.command])),
        .holdKeystroke(KeyChord(keyCode: 63, modifiers: [])),
        .focusTextInput,
    ]
    for action in requiresAccessibilityActions {
        #expect(action.requiresAccessibility == true)
        let spy = Spy()
        spy.isAccessibilityTrustedResult = false
        let outcome = await makeDispatcher(spy).dispatch(action)
        #expect(outcome == .needsAccessibility)
        #expect(spy.isAccessibilityTrustedCallCount == 1)
    }

    let noAccessibilityActions: [TacitAction] = [
        .launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .openURL("superwhisper://record"),
        .runShortcut(name: "Focus"),
        .switchApp(.next),
    ]
    for action in noAccessibilityActions {
        #expect(action.requiresAccessibility == false)
        let spy = Spy()
        spy.isAccessibilityTrustedResult = false
        let outcome = await makeDispatcher(spy).dispatch(action)
        #expect(outcome != .needsAccessibility)
        #expect(spy.isAccessibilityTrustedCallCount == 0)
    }
}
