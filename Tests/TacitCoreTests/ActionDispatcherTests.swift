import Foundation
import Testing
@testable import TacitCore

// MARK: - TacitAction

@Test func requiresAccessibilityIsTrueOnlyForKeystroke() {
    #expect(TacitAction.keystroke(KeyChord(keyCode: 8, modifiers: [.command])).requiresAccessibility == true)
    #expect(TacitAction.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").requiresAccessibility == false)
    #expect(TacitAction.openURL("superwhisper://record").requiresAccessibility == false)
    #expect(TacitAction.runShortcut(name: "Focus").requiresAccessibility == false)
}

@Test func summaryDescribesEachAction() {
    #expect(TacitAction.keystroke(KeyChord(keyCode: 8, modifiers: [.command])).summary == "⌘C")
    #expect(TacitAction.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").summary == "Open Ghostty")
    #expect(TacitAction.openURL("superwhisper://record").summary == "superwhisper://record")
    #expect(TacitAction.runShortcut(name: "Focus").summary == "Shortcut: Focus")
}

@Test func tacitActionCodableRoundTrips() throws {
    let actions: [TacitAction] = [
        .keystroke(KeyChord(keyCode: 8, modifiers: [.command])),
        .launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .openURL("superwhisper://record"),
        .runShortcut(name: "Focus"),
    ]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(TacitAction.self, from: data)
        #expect(decoded == action)
    }
}

// MARK: - ActionDispatcher

/// A spy environment that records which closures were invoked and lets each call succeed or
/// fail on demand. Dispatch is synchronous and single-threaded within a single test, so the
/// unchecked Sendable conformance is safe here.
private final class Spy: @unchecked Sendable {
    var postKeystrokeCalls: [KeyChord] = []
    var launchAppCalls: [String] = []
    var openURLCalls: [String] = []
    var runShortcutCalls: [String] = []
    var isAccessibilityTrustedCallCount = 0

    var postKeystrokeResult = true
    var launchAppResult = true
    var openURLResult = true
    var runShortcutResult = true
    var isAccessibilityTrustedResult = true
}

private func makeDispatcher(_ spy: Spy) -> ActionDispatcher {
    ActionDispatcher(environment: ActionEnvironment(
        postKeystroke: { chord in spy.postKeystrokeCalls.append(chord); return spy.postKeystrokeResult },
        launchApp: { bundleID in spy.launchAppCalls.append(bundleID); return spy.launchAppResult },
        openURL: { string in spy.openURLCalls.append(string); return spy.openURLResult },
        runShortcut: { name in spy.runShortcutCalls.append(name); return spy.runShortcutResult },
        isAccessibilityTrusted: { spy.isAccessibilityTrustedCallCount += 1; return spy.isAccessibilityTrustedResult }
    ))
}

@Test func dispatchKeystrokeCallsPostKeystrokeWhenTrusted() {
    let spy = Spy()
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .performed)
    #expect(spy.postKeystrokeCalls == [chord])
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
}

@Test func dispatchKeystrokeReturnsNeedsAccessibilityWithoutPostingWhenUntrusted() {
    let spy = Spy()
    spy.isAccessibilityTrustedResult = false
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .needsAccessibility)
    #expect(spy.postKeystrokeCalls.isEmpty)
}

@Test func dispatchKeystrokeFailsWithSummaryInMessage() {
    let spy = Spy()
    spy.postKeystrokeResult = false
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    let outcome = makeDispatcher(spy).dispatch(.keystroke(chord))
    #expect(outcome == .failed("Couldn't press ⌘C"))
}

@Test func dispatchLaunchAppCallsExactlyLaunchApp() {
    let spy = Spy()
    let outcome = makeDispatcher(spy).dispatch(.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"))
    #expect(outcome == .performed)
    #expect(spy.launchAppCalls == ["com.mitchellh.ghostty"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchLaunchAppFailsWithDisplayNameInMessage() {
    let spy = Spy()
    spy.launchAppResult = false
    let outcome = makeDispatcher(spy).dispatch(.launchApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"))
    #expect(outcome == .failed("Couldn't open Ghostty"))
}

@Test func dispatchOpenURLCallsExactlyOpenURL() {
    let spy = Spy()
    let outcome = makeDispatcher(spy).dispatch(.openURL("superwhisper://record"))
    #expect(outcome == .performed)
    #expect(spy.openURLCalls == ["superwhisper://record"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.runShortcutCalls.isEmpty)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchOpenURLFailsWithURLInMessage() {
    let spy = Spy()
    spy.openURLResult = false
    let outcome = makeDispatcher(spy).dispatch(.openURL("superwhisper://record"))
    #expect(outcome == .failed("Couldn't open superwhisper://record"))
}

@Test func dispatchRunShortcutCallsExactlyRunShortcut() {
    let spy = Spy()
    let outcome = makeDispatcher(spy).dispatch(.runShortcut(name: "Focus"))
    #expect(outcome == .performed)
    #expect(spy.runShortcutCalls == ["Focus"])
    #expect(spy.postKeystrokeCalls.isEmpty)
    #expect(spy.launchAppCalls.isEmpty)
    #expect(spy.openURLCalls.isEmpty)
    #expect(spy.isAccessibilityTrustedCallCount == 0)
}

@Test func dispatchRunShortcutFailsWithNameInMessage() {
    let spy = Spy()
    spy.runShortcutResult = false
    let outcome = makeDispatcher(spy).dispatch(.runShortcut(name: "Focus"))
    #expect(outcome == .failed("Couldn't run Shortcut 'Focus'"))
}
