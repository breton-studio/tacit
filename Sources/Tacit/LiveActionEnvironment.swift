@preconcurrency import ApplicationServices
import AppKit
import ServiceManagement
import TacitCore
import OSLog

/// The real macOS implementation of `ActionEnvironment` — posts synthetic key events, launches
/// apps, opens URLs, and runs Shortcuts. Kept deliberately dumb (no logic beyond translating one
/// closure call into the matching system call); the branching/decision logic lives in
/// `ActionDispatcher`, which is unit-tested with spy environments instead.
enum LiveActionEnvironment {
    /// `KeyChord.Modifiers` → `CGEventFlags`, shared by `postKeystroke`/`postKeyDown`/`postKeyUp`
    /// below so the three don't each re-derive the same mapping.
    private static func cgEventFlags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    static func make() -> ActionEnvironment {
        ActionEnvironment(
            postKeystroke: { chord in
                let flags = cgEventFlags(for: chord.modifiers)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false)
                else {
                    TacitLog.actions.info(
                        "postKeystroke keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) CGEvent creation failed"
                    )
                    return false
                }
                down.flags = flags; up.flags = flags
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                TacitLog.actions.info(
                    "postKeystroke keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) down+up posted"
                )
                return true
            },
            // M3 Task 9: the down-only/up-only halves `TacitEngine`'s hold-began/hold-ended paths
            // call directly (never through `ActionDispatcher.dispatch(_:)`) so a `.holdKeystroke`
            // gesture can stay held across many frames between the two calls.
            //
            // SPECIAL CASE — keyCode 63 (Fn): a bare `CGEvent(keyboardEventSource:virtualKey:63,…)`
            // does not reliably deliver an actual "Fn" signal to listeners; macOS represents the Fn
            // key primarily as a MODIFIER FLAG (`.maskSecondaryFn`) on a flags-changed-style event,
            // not as an ordinary virtual-key down/up. So for keyCode 63 specifically, this ALSO sets
            // `.maskSecondaryFn` on the down event's flags (and the up event explicitly omits it,
            // i.e. "clears" it relative to down) — best-effort: whether a given listening app (e.g.
            // Wispr Flow, the "point to speak" dictation target this exists for) actually treats
            // that as a real Fn press likely needs verification on a real device; this is
            // documented here rather than guaranteed.
            postKeyDown: { chord in
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: true)
                else {
                    TacitLog.actions.info(
                        "postKeyDown keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) CGEvent creation failed"
                    )
                    return false
                }
                var flags = cgEventFlags(for: chord.modifiers)
                if chord.keyCode == 63 { flags.insert(.maskSecondaryFn) }
                down.flags = flags
                down.post(tap: .cghidEventTap)
                TacitLog.actions.info(
                    "postKeyDown keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) posted"
                )
                return true
            },
            postKeyUp: { chord in
                guard let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false)
                else {
                    TacitLog.actions.info(
                        "postKeyUp keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) CGEvent creation failed"
                    )
                    return false
                }
                // `.maskSecondaryFn` is deliberately NOT set here — the up event represents Fn's
                // release, so its flags must NOT carry the "Fn is down" bit forward.
                up.flags = cgEventFlags(for: chord.modifiers)
                up.post(tap: .cghidEventTap)
                TacitLog.actions.info(
                    "postKeyUp keyCode=\(chord.keyCode, privacy: .public) modifiers=\(chord.modifiers.rawValue, privacy: .public) posted"
                )
                return true
            },
            launchApp: { bundleID in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return true
            },
            openURL: { string in
                guard let url = URL(string: string) else { return false }
                return NSWorkspace.shared.open(url)
            },
            // NOTE: `waitUntilExit()` blocks the calling thread until `shortcuts run` completes.
            // This is fine for `ActionDispatcher.dispatch`, which callers (Task 21's TacitEngine
            // wiring) must invoke off the main thread/actor — never call `dispatch` synchronously
            // from a main-thread context, or a slow Shortcut will hang the UI.
            runShortcut: { name in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["run", name]
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            },
            // M3 Task 10: BLOCKS BRIEFLY — every `AXUIElementCopyAttributeValue` call below is a
            // synchronous round-trip into another process (potentially a hung or slow one), so
            // this must only ever run off the main thread/actor. Its sole caller,
            // `ActionDispatcher.dispatch(_:)`, is itself only ever invoked from `TacitEngine`'s
            // `Task.detached` in `handleFire(_:)` — see that call site's doc comment — never
            // synchronously from the main actor.
            focusTextInput: { AXTextInputFocuser.focusFrontmostTextInput() },
            isAccessibilityTrusted: { AXIsProcessTrusted() }
        )
    }
}

/// M3 Task 10: the `focusTextInput` action's Accessibility-API search + focus, split out of
/// `LiveActionEnvironment.make()` into its own enum purely for readability (the algorithm has
/// enough steps to want named helper functions rather than one giant closure literal).
enum AXTextInputFocuser {
    /// Search order, in full:
    /// 1. `NSWorkspace.shared.frontmostApplication` → its `AXUIElementCreateApplication(pid)`.
    /// 2. That app's `kAXFocusedWindowAttribute`; if absent, the FIRST element of
    ///    `kAXWindowsAttribute` instead.
    /// 3. A breadth-first walk of that window's `kAXChildrenAttribute` tree, capped at depth ≤ 8
    ///    and ≤ 400 nodes VISITED (both caps exist so a pathological AX tree — e.g. a web page
    ///    with thousands of DOM-backed accessibility elements — can't turn one gesture fire into
    ///    a multi-second hang), collecting elements whose `kAXRoleAttribute` is one of
    ///    `AXTextArea`/`AXTextField`/`AXSearchField`/`AXComboBox`.
    /// 4. Of what the walk finds: prefer the FIRST `AXTextArea` encountered (BFS order — shallower
    ///    wins, then left-to-right among siblings); if none, the first element of any of the other
    ///    three roles found. The walk short-circuits the moment an `AXTextArea` is found (nothing
    ///    later in BFS order could ever outrank it), but must otherwise exhaust the node budget
    ///    before falling back to an "other role" candidate, since a same-depth-or-later
    ///    `AXTextArea` could still be waiting.
    /// 5. Focus the winning element: set `kAXFocusedAttribute` to `true`. If that fails, fall back
    ///    to `kAXRaiseAction` (best-effort, bring its window forward; failure here is ignored —
    ///    it's an aid, not the goal) followed by `kAXPressAction` (click-equivalent, often focuses
    ///    a field as a side effect); the overall call succeeds iff `kAXPressAction` succeeds.
    /// Returns `false` if any REQUIRED step fails: no frontmost app, no window, no matching
    /// element found by the walk, or both the direct-focus and click-fallback focus attempts fail.
    static func focusFrontmostTextInput() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let appElement = AXUIElementCreateApplication(pid)

        guard let window = focusedOrFirstWindow(of: appElement) else { return false }
        guard let target = firstMatchingTextElement(startingAt: window) else { return false }
        return focus(target)
    }

    /// Step 2: `kAXFocusedWindowAttribute`, falling back to the first `kAXWindowsAttribute` entry.
    private static func focusedOrFirstWindow(of appElement: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = copyAttribute(appElement, kAXFocusedWindowAttribute) {
            return focused
        }
        let windows: [AXUIElement] = copyAttribute(appElement, kAXWindowsAttribute) ?? []
        return windows.first
    }

    /// Step 3+4: the capped breadth-first walk + role preference described in the doc comment
    /// above.
    private static func firstMatchingTextElement(startingAt root: AXUIElement) -> AXUIElement? {
        let maxDepth = 8
        let maxNodes = 400
        let preferredRole = "AXTextArea"
        let fallbackRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]

        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var nodesVisited = 0
        var firstFallback: AXUIElement?

        while !queue.isEmpty, nodesVisited < maxNodes {
            let (element, depth) = queue.removeFirst()
            nodesVisited += 1

            if let role: String = copyAttribute(element, kAXRoleAttribute) {
                if role == preferredRole {
                    return element // Nothing later in BFS order can outrank this — stop now.
                }
                if firstFallback == nil, fallbackRoles.contains(role) {
                    firstFallback = element
                }
            }

            if depth < maxDepth {
                let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) ?? []
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }

        return firstFallback
    }

    /// Step 5: direct focus, falling back to raise-then-press.
    private static func focus(_ element: AXUIElement) -> Bool {
        let setResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if setResult == .success { return true }

        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString) // best-effort; ignored
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return pressResult == .success
    }

    /// `AXUIElementCopyAttributeValue` writes its result through a `CFTypeRef?` (`AnyObject?` in
    /// Swift) out-parameter shared by every attribute type (`AXUIElement`, `CFArray`, `CFString`,
    /// `CFBoolean`, …) — the AX API is not statically typed per attribute. This wraps that into a
    /// generic helper returning `nil` on any `AXError` OTHER than `.success`, or if the value
    /// can't be cast to `T` (e.g. an attribute that's absent on this element, or of a type the
    /// caller didn't expect). No manual `Unmanaged`/retain-release bookkeeping is needed here:
    /// `AXUIElementCopyAttributeValue`'s out-parameter is CF-audited as "copy" (caller-owned) and
    /// Swift's importer already hands back a normally-ARC-managed `AnyObject`, exactly like every
    /// other `Copy`-named CoreFoundation API — see e.g. `AccessibilityPermission` above, which
    /// DOES need `Unmanaged`/`takeUnretainedValue()`, but only because `kAXTrustedCheckOptionPrompt`
    /// is a bare global `CFString` constant (no Create/Copy call involved), not because of
    /// anything AX-specific.
    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
}

/// Prompts the user for Accessibility access (spec §7's `AXIsProcessTrustedWithOptions`) if not
/// already granted — shared by `OnboardingView`'s Accessibility step and the Library's
/// keystroke-card notice (`ActionBinderView`, Task 20), so both places request access the exact
/// same way instead of duplicating the call.
///
/// `kAXTrustedCheckOptionPrompt` is declared as a plain (non-`Sendable`) global `CFString` var in
/// the ApplicationServices C header, so Swift 6's strict concurrency checker flags even a read of
/// it as unsafe shared mutable state. `nonisolated(unsafe)` documents that this is fine in
/// practice — it's an OS-provided constant, never mutated after load — mirroring the same escape
/// hatch `CaptureEngine`/`FixtureRecorder` already use elsewhere in this codebase for SDK globals
/// the compiler can't see are safe.
enum AccessibilityPermission {
    private nonisolated(unsafe) static let promptOptionKey = kAXTrustedCheckOptionPrompt

    static func requestPromptIfNeeded() {
        let key = promptOptionKey.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Task 21 controller ruling (R5): launch-at-login defaults to ON for a fresh install. Runs at
/// most once ever — gated by `tacit.launchAtLoginConfigured`, which is set regardless of whether
/// `register()` actually succeeds — so this never re-fires on a later launch, and never fights a
/// user who deliberately turns the toggle back off afterward. `LaunchAtLoginToggleRow`'s (M3 Task
/// 7: shared by `PopoverView` and the Library window's `SettingsTab`, see `SharedControls.swift`)
/// "Launch at Login" toggle is unaffected by this (and unaware of it): it reads
/// `SMAppService.mainApp.status` directly, so it continues to reflect whatever the real system
/// state is either way.
enum LaunchAtLoginDefault {
    private static let configuredDefaultsKey = "tacit.launchAtLoginConfigured"

    static func configureIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: configuredDefaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
        try? SMAppService.mainApp.register() // best-effort; failure is ignored gracefully.
    }
}
