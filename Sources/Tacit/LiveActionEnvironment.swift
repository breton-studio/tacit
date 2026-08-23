@preconcurrency import ApplicationServices
import AppKit
import TacitCore

/// The real macOS implementation of `ActionEnvironment` — posts synthetic key events, launches
/// apps, opens URLs, and runs Shortcuts. Kept deliberately dumb (no logic beyond translating one
/// closure call into the matching system call); the branching/decision logic lives in
/// `ActionDispatcher`, which is unit-tested with spy environments instead.
enum LiveActionEnvironment {
    static func make() -> ActionEnvironment {
        ActionEnvironment(
            postKeystroke: { chord in
                var flags = CGEventFlags()
                if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
                if chord.modifiers.contains(.shift)   { flags.insert(.maskShift) }
                if chord.modifiers.contains(.option)  { flags.insert(.maskAlternate) }
                if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false)
                else { return false }
                down.flags = flags; up.flags = flags
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
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
