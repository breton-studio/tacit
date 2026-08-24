@preconcurrency import ApplicationServices
import AppKit
import ServiceManagement
import TacitCore

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
                else { return false }
                down.flags = flags; up.flags = flags
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
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
                else { return false }
                var flags = cgEventFlags(for: chord.modifiers)
                if chord.keyCode == 63 { flags.insert(.maskSecondaryFn) }
                down.flags = flags
                down.post(tap: .cghidEventTap)
                return true
            },
            postKeyUp: { chord in
                guard let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false)
                else { return false }
                // `.maskSecondaryFn` is deliberately NOT set here — the up event represents Fn's
                // release, so its flags must NOT carry the "Fn is down" bit forward.
                up.flags = cgEventFlags(for: chord.modifiers)
                up.post(tap: .cghidEventTap)
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
            isAccessibilityTrusted: { AXIsProcessTrusted() }
        )
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
