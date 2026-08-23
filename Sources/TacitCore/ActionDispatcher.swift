import Foundation

/// The side effects a `TacitAction` needs, injected as closures so `TacitCore` never imports
/// AppKit/CoreGraphics. The app target supplies a live implementation (see
/// `LiveActionEnvironment`); tests supply spies.
public struct ActionEnvironment: Sendable {
    public var postKeystroke: @Sendable (KeyChord) -> Bool
    public var launchApp: @Sendable (String) -> Bool
    public var openURL: @Sendable (String) -> Bool
    public var runShortcut: @Sendable (String) -> Bool
    public var isAccessibilityTrusted: @Sendable () -> Bool

    public init(
        postKeystroke: @Sendable @escaping (KeyChord) -> Bool,
        launchApp: @Sendable @escaping (String) -> Bool,
        openURL: @Sendable @escaping (String) -> Bool,
        runShortcut: @Sendable @escaping (String) -> Bool,
        isAccessibilityTrusted: @Sendable @escaping () -> Bool
    ) {
        self.postKeystroke = postKeystroke
        self.launchApp = launchApp
        self.openURL = openURL
        self.runShortcut = runShortcut
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }
}

/// The result of attempting to dispatch a `TacitAction`.
public enum DispatchOutcome: Equatable, Sendable {
    case performed
    /// A `.keystroke` couldn't be attempted because Accessibility permission isn't granted.
    /// `postKeystroke` is deliberately not called in this case.
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
        switch action {
        case .keystroke(let chord):
            guard environment.isAccessibilityTrusted() else { return .needsAccessibility }
            guard environment.postKeystroke(chord) else {
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
        }
    }
}
