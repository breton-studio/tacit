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
    public var runShortcut: @Sendable (String) -> Bool
    /// M3 Task 10: finds and focuses the frontmost window's main text input via the Accessibility
    /// API; returns `false` if no suitable text element could be found/focused (the AX search
    /// itself lives in `LiveActionEnvironment` — see its doc comment for the search order/limits).
    public var focusTextInput: @Sendable () -> Bool
    public var isAccessibilityTrusted: @Sendable () -> Bool

    public init(
        postKeystroke: @Sendable @escaping (KeyChord) -> Bool,
        postKeyDown: @Sendable @escaping (KeyChord) -> Bool,
        postKeyUp: @Sendable @escaping (KeyChord) -> Bool,
        launchApp: @Sendable @escaping (String) -> Bool,
        openURL: @Sendable @escaping (String) -> Bool,
        runShortcut: @Sendable @escaping (String) -> Bool,
        focusTextInput: @Sendable @escaping () -> Bool,
        isAccessibilityTrusted: @Sendable @escaping () -> Bool
    ) {
        self.postKeystroke = postKeystroke
        self.postKeyDown = postKeyDown
        self.postKeyUp = postKeyUp
        self.launchApp = launchApp
        self.openURL = openURL
        self.runShortcut = runShortcut
        self.focusTextInput = focusTextInput
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

    public func dispatch(_ action: TacitAction) -> DispatchOutcome {
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
            guard environment.runShortcut(name) else {
                return .failed("Couldn't run Shortcut '\(name)'")
            }
            return .performed

        case .focusTextInput:
            guard environment.focusTextInput() else {
                return .failed("Couldn't find a text field.")
            }
            return .performed
        }
    }
}
