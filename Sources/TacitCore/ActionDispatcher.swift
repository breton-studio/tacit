import Foundation

/// The side effects a `TacitAction` needs, injected as closures so `TacitCore` never imports
/// AppKit/CoreGraphics. The app target supplies a live implementation (see
/// `LiveActionEnvironment`); tests supply spies.
public struct ActionEnvironment: Sendable {
    public var postKeystroke: @Sendable (KeyChord) -> Bool
    /// M3 Task 9: posts ONLY the key-down half of `chord` — the paired `postKeyUp` is a SEPARATE
    /// call the caller is responsible for making later. Used by `TacitEngine`'s hold-began path
    /// directly (bypassing `ActionDispatcher.dispatch(_:)`), and by `dispatch(_:)`'s own
    /// `.holdKeystroke` full-press fallback (down, then up).
    public var postKeyDown: @Sendable (KeyChord) -> Bool
    /// M3 Task 9: posts ONLY the key-up half of `chord`. See `postKeyDown`'s doc comment — every
    /// `postKeyDown` this environment is asked to perform must eventually be paired with exactly
    /// one `postKeyUp` of the same chord, or a key is left stuck down.
    public var postKeyUp: @Sendable (KeyChord) -> Bool
    public var launchApp: @Sendable (String) -> Bool
    public var openURL: @Sendable (String) -> Bool
    /// Code review 2026-08-27, Finding 4 / item (e): `async` so the real implementation
    /// (`LiveActionEnvironment.runShortcut`) can await `Process` termination via a continuation +
    /// timeout instead of blocking the calling thread on `waitUntilExit()`. See that file's doc
    /// comment for the timeout mechanism.
    public var runShortcut: @Sendable (String) async -> Bool
    /// M3 Task 10: finds and focuses the frontmost window's main text input via the Accessibility
    /// API; returns `false` if no suitable text element could be found/focused (the AX search
    /// itself lives in `LiveActionEnvironment` — see its doc comment for the search order/limits).
    /// Code review 2026-08-27, Finding 4 / item (e): `async` alongside `runShortcut`/`switchApp` —
    /// see `ActionDispatcher.dispatch(_:)`'s doc comment for why all three had to move together.
    public var focusTextInput: @Sendable () async -> Bool
    /// 2026-08-24 product ruling: activates the next/previous app in the frozen MRU flip ring
    /// DIRECTLY (`NSRunningApplication.activate`) — never posts ⌘Tab, never shows the switcher.
    /// Returns `false` if there was nothing to activate (e.g. an empty snapshot). The ring itself
    /// (`AppSwitchRing`) and its `NSWorkspace` owner (`AppSwitcher`) live in the app target — see
    /// `LiveActionEnvironment.make()`. Code review 2026-08-27, Finding 4 / item (e): `async` so
    /// the real implementation can `await MainActor.run { ... }` instead of blocking the calling
    /// thread on `DispatchQueue.main.sync`.
    public var switchApp: @Sendable (AppSwitchDirection) async -> Bool
    public var isAccessibilityTrusted: @Sendable () -> Bool

    public init(
        postKeystroke: @Sendable @escaping (KeyChord) -> Bool,
        postKeyDown: @Sendable @escaping (KeyChord) -> Bool,
        postKeyUp: @Sendable @escaping (KeyChord) -> Bool,
        launchApp: @Sendable @escaping (String) -> Bool,
        openURL: @Sendable @escaping (String) -> Bool,
        runShortcut: @Sendable @escaping (String) async -> Bool,
        focusTextInput: @Sendable @escaping () async -> Bool,
        switchApp: @Sendable @escaping (AppSwitchDirection) async -> Bool,
        isAccessibilityTrusted: @Sendable @escaping () -> Bool
    ) {
        self.postKeystroke = postKeystroke
        self.postKeyDown = postKeyDown
        self.postKeyUp = postKeyUp
        self.launchApp = launchApp
        self.openURL = openURL
        self.runShortcut = runShortcut
        self.focusTextInput = focusTextInput
        self.switchApp = switchApp
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }
}

/// The result of attempting to dispatch a `TacitAction`.
public enum DispatchOutcome: Equatable, Sendable {
    case performed
    /// A `.keystroke`/`.holdKeystroke` couldn't be attempted because Accessibility permission
    /// isn't granted. Neither `postKeystroke` nor `postKeyDown`/`postKeyUp` is called in this case.
    case needsAccessibility
    /// A plain-verb user-facing message, e.g. "Couldn't run Shortcut 'Focus'".
    case failed(String)
}

/// Routes a `TacitAction` to the matching closure on an `ActionEnvironment`.
public struct ActionDispatcher: Sendable {
    private let environment: ActionEnvironment

    public init(environment: ActionEnvironment) {
        self.environment = environment
    }

    /// Code review 2026-08-27, Finding 4 / item (e): `async` so `.runShortcut`/`.focusTextInput`/
    /// `.switchApp` — the three blocking calls Finding 4 identified — can leave the Swift
    /// cooperative thread pool instead of starving it (`Process.waitUntilExit()`, up to 400
    /// synchronous cross-process AX calls with no messaging timeout, and `DispatchQueue.main.sync`,
    /// respectively; see `LiveActionEnvironment.swift` for each fix). `.keystroke`/`.holdKeystroke`/
    /// `.toggleKeystroke` still go through this same switch below (and `ActionDispatcherTests`
    /// still exercises them directly, synchronously awaited), but `TacitEngine.handleFire(_:)`'s
    /// production call site no longer routes those three cases through this method at all —
    /// `await`ing this `async` function is a suspension point, and yielding the main actor there
    /// would reintroduce Finding 5 / item (c)'s keystroke-ordering bug. See
    /// `TacitEngine.dispatchKeystrokeShapedActionSynchronously(_:)`'s doc comment for the
    /// synchronous substitute `handleFire(_:)` calls instead, which duplicates this method's
    /// `.keystroke`/`.holdKeystroke`/`.toggleKeystroke` logic deliberately rather than delegating to
    /// it.
    public func dispatch(_ action: TacitAction) async -> DispatchOutcome {
        // M3 Task 10: the Accessibility gate is derived from `action.requiresAccessibility`
        // GENERICALLY, once, up front — rather than each case re-implementing its own
        // `guard environment.isAccessibilityTrusted() else { return .needsAccessibility }`. This
        // is the invariant that guarantees every case for which `requiresAccessibility` is true
        // (currently `.keystroke`, `.holdKeystroke`, `.toggleKeystroke`, `.focusTextInput`) gets
        // the gate, and that a
        // FUTURE case added with `requiresAccessibility == true` gets it automatically too,
        // without anyone having to remember to copy the guard into a new case body. Cases with
        // `requiresAccessibility == false` never call `isAccessibilityTrusted()` at all (verified
        // by the dispatcher tests' call-count assertions), matching the previous per-case
        // behavior exactly.
        if action.requiresAccessibility, !environment.isAccessibilityTrusted() {
            return .needsAccessibility
        }

        switch action {
        case .keystroke(let chord):
            guard environment.postKeystroke(chord) else {
                return .failed("Couldn't press \(chord.display)")
            }
            return .performed

        case .holdKeystroke(let chord):
            // M3 Task 9: `.holdKeystroke`'s intended lifecycle (key-down on hold-begin, key-up on
            // hold-end) is driven by `TacitEngine` calling `postKeyDown`/`postKeyUp` DIRECTLY —
            // this branch is never reached on that path. It exists purely as the FALLBACK for a
            // plain *fire* of a gesture bound to `.holdKeystroke` with no hold support behind it
            // (e.g. a momentary gesture like a tap, which can never produce a `HoldTracker`
            // began/ended pair): dispatched through this normal fire path, it performs a full
            // press — down, then up — so the binding still does SOMETHING sensible rather than
            // silently posting a key-down with no matching key-up.
            guard environment.postKeyDown(chord) else {
                return .failed("Couldn't press \(chord.display)")
            }
            guard environment.postKeyUp(chord) else {
                return .failed("Couldn't press \(chord.display)")
            }
            return .performed

        case .toggleKeystroke(let chord):
            // Same fallback shape as `.holdKeystroke` above: the latch lifecycle lives in
            // `TacitEngine`; a bare fire through this path performs a full press so the binding
            // still does something sensible and never leaves a key down.
            guard environment.postKeyDown(chord) else {
                return .failed("Couldn't press \(chord.display)")
            }
            guard environment.postKeyUp(chord) else {
                return .failed("Couldn't press \(chord.display)")
            }
            return .performed

        case .launchApp(let bundleID, let displayName):
            guard environment.launchApp(bundleID) else {
                return .failed("Couldn't open \(displayName)")
            }
            return .performed

        case .openURL(let string):
            guard environment.openURL(string) else {
                return .failed("Couldn't open \(string)")
            }
            return .performed

        case .runShortcut(let name):
            guard await environment.runShortcut(name) else {
                return .failed("Couldn't run Shortcut '\(name)'")
            }
            return .performed

        case .focusTextInput:
            guard await environment.focusTextInput() else {
                return .failed("Couldn't find a text field.")
            }
            return .performed

        case .switchApp(let direction):
            guard await environment.switchApp(direction) else {
                return .failed("Couldn't switch app")
            }
            return .performed
        }
    }
}
