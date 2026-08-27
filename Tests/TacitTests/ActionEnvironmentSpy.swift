import Foundation
import TacitCore
@testable import Tacit

/// A thread-safe, `Sendable` spy `ActionEnvironment` for `TacitTests` (code review 2026-08-27,
/// Finding 2 / item (d)).
///
/// ## Why this needs real locking, unlike `ActionDispatcherTests`' spy
///
/// `Tests/TacitCoreTests/ActionDispatcherTests.swift`'s `Spy` is `@unchecked Sendable` on the
/// documented assumption that "dispatch is synchronous and single-threaded within a single
/// test" — true there, because that suite calls `ActionDispatcher.dispatch(_:)` directly.
///
/// That assumption does NOT hold for `TacitEngine`. As of item (c) (2026-08-27),
/// `handleFire(_:)` dispatches `.keystroke`/`.holdKeystroke`/`.toggleKeystroke` SYNCHRONOUSLY on
/// the main actor (bypassing `ActionDispatcher.dispatch(_:)` entirely as of item (e) — see
/// `TacitEngine.dispatchKeystrokeShapedActionSynchronously(_:)`), but `.launchApp`/`.openURL`/
/// `.runShortcut`/`.focusTextInput`/`.switchApp` still go through `Task.detached` — and, as of
/// item (e) (Finding 4), `await actionDispatcher.dispatch(action)` inside it, so these three
/// closures below are now `async` too — and can call this environment's closures from an
/// arbitrary background thread. So this spy can legitimately be called from more than one thread,
/// including concurrently with a main-actor caller. Every read and write below goes through a
/// single `NSLock` rather than relying on "tests are single-threaded."
///
/// ## API surface (verbatim — the three agents writing the seven invariant tests use this)
///
/// - `ActionEnvironmentSpy(isAccessibilityTrusted: Bool = true)` — designated initializer.
/// - `spy.makeEnvironment() -> ActionEnvironment` — builds the real `ActionEnvironment` to inject
///   into `TacitEngine.init(actionEnvironment:)`. Call this once per spy; every closure it
///   returns records into the SAME spy instance.
/// - `spy.isAccessibilityTrusted: Bool` — get/set. Settable AT ANY TIME, including mid-test,
///   after the environment has already been injected into a live `TacitEngine` — this is what
///   lets a test simulate "Accessibility revoked between two gesture fires."
/// - `spy.keyLog: [KeyOperation]` — the ORDERED log of every `postKeyDown`/`postKeyUp`/
///   `postKeystroke` call, oldest first. `KeyOperation` is `{ kind: KeyOperationKind, chord:
///   KeyChord }`, `Equatable`, so a test can assert e.g.
///   `#expect(spy.keyLog == [.init(kind: .down, chord: fn), .init(kind: .up, chord: fn)])`.
/// - `spy.nonKeyboardLog: [NonKeyboardOperation]` — the ORDERED log of every `launchApp`/
///   `openURL`/`runShortcut`/`focusTextInput`/`switchApp` call, oldest first, as an `Equatable`
///   enum (`.launchApp(String)`, `.openURL(String)`, `.runShortcut(String)`, `.focusTextInput`,
///   `.switchApp(AppSwitchDirection)`).
/// - `spy.postKeystrokeResult` / `postKeyDownResult` / `postKeyUpResult` / `launchAppResult` /
///   `openURLResult` / `runShortcutResult` / `focusTextInputResult` / `switchAppResult` — `Bool`,
///   default `true`. Set `false` before firing to make that closure report failure (mirrors
///   `ActionDispatcherTests.Spy`'s `*Result` flags) and drive `ActionDispatcher.dispatch`'s
///   `.failed(_:)` path.
/// - `spy.clearLogs()` — empties both logs in place (keeps `isAccessibilityTrusted` and every
///   `*Result` flag as they were). Useful between two phases of the same test (e.g. "assert the
///   engage log, clear it, then assert the release log in isolation").
///
/// See `Tests/TacitTests/README.md` for a full worked example, including how to drive a gesture
/// through the engine to `handleFire(_:)`.
public final class ActionEnvironmentSpy: @unchecked Sendable {

    // MARK: Log element types

    public enum KeyOperationKind: String, Equatable, Sendable {
        case down, up, press
    }

    public struct KeyOperation: Equatable, Sendable {
        public let kind: KeyOperationKind
        public let chord: KeyChord

        public init(kind: KeyOperationKind, chord: KeyChord) {
            self.kind = kind
            self.chord = chord
        }
    }

    public enum NonKeyboardOperation: Equatable, Sendable {
        case launchApp(String)
        case openURL(String)
        case runShortcut(String)
        case focusTextInput
        case switchApp(AppSwitchDirection)
    }

    // MARK: Locked storage

    private let lock = NSLock()
    private var _keyLog: [KeyOperation] = []
    private var _nonKeyboardLog: [NonKeyboardOperation] = []
    private var _isAccessibilityTrusted: Bool
    private var _postKeystrokeResult = true
    private var _postKeyDownResult = true
    private var _postKeyUpResult = true
    private var _launchAppResult = true
    private var _openURLResult = true
    private var _runShortcutResult = true
    private var _focusTextInputResult = true
    private var _switchAppResult = true

    /// - Parameter isAccessibilityTrusted: the initial value `isAccessibilityTrusted()` returns.
    ///   Defaults to `true` (the common case — most invariants are about ordering/pairing, not
    ///   the Accessibility gate itself). Flip `spy.isAccessibilityTrusted` mid-test for the
    ///   "toggle engaged → Accessibility revoked → second toggle still releases" invariant.
    public init(isAccessibilityTrusted: Bool = true) {
        self._isAccessibilityTrusted = isAccessibilityTrusted
    }

    // MARK: Test-side reads

    /// The ordered log of every `postKeyDown`/`postKeyUp`/`postKeystroke` call, oldest first.
    public var keyLog: [KeyOperation] {
        lock.withLock { _keyLog }
    }

    /// The ordered log of every `launchApp`/`openURL`/`runShortcut`/`focusTextInput`/`switchApp`
    /// call, oldest first.
    public var nonKeyboardLog: [NonKeyboardOperation] {
        lock.withLock { _nonKeyboardLog }
    }

    /// Empties both logs in place. Does not touch `isAccessibilityTrusted` or any `*Result` flag.
    public func clearLogs() {
        lock.withLock {
            _keyLog.removeAll()
            _nonKeyboardLog.removeAll()
        }
    }

    // MARK: Test-side controls

    /// What `isAccessibilityTrusted()` currently returns. Settable at any time, including after
    /// the environment built from this spy has already been injected into a live `TacitEngine`.
    public var isAccessibilityTrusted: Bool {
        get { lock.withLock { _isAccessibilityTrusted } }
        set { lock.withLock { _isAccessibilityTrusted = newValue } }
    }

    public var postKeystrokeResult: Bool {
        get { lock.withLock { _postKeystrokeResult } }
        set { lock.withLock { _postKeystrokeResult = newValue } }
    }

    public var postKeyDownResult: Bool {
        get { lock.withLock { _postKeyDownResult } }
        set { lock.withLock { _postKeyDownResult = newValue } }
    }

    public var postKeyUpResult: Bool {
        get { lock.withLock { _postKeyUpResult } }
        set { lock.withLock { _postKeyUpResult = newValue } }
    }

    public var launchAppResult: Bool {
        get { lock.withLock { _launchAppResult } }
        set { lock.withLock { _launchAppResult = newValue } }
    }

    public var openURLResult: Bool {
        get { lock.withLock { _openURLResult } }
        set { lock.withLock { _openURLResult = newValue } }
    }

    public var runShortcutResult: Bool {
        get { lock.withLock { _runShortcutResult } }
        set { lock.withLock { _runShortcutResult = newValue } }
    }

    public var focusTextInputResult: Bool {
        get { lock.withLock { _focusTextInputResult } }
        set { lock.withLock { _focusTextInputResult = newValue } }
    }

    public var switchAppResult: Bool {
        get { lock.withLock { _switchAppResult } }
        set { lock.withLock { _switchAppResult = newValue } }
    }

    // MARK: ActionEnvironment construction

    /// Builds a real `ActionEnvironment` whose every closure records into THIS spy instance
    /// (under the same lock as every accessor above) and returns the matching `*Result` flag.
    /// Call once; pass the result straight to `TacitEngine.init(actionEnvironment:)`.
    public func makeEnvironment() -> ActionEnvironment {
        ActionEnvironment(
            postKeystroke: { [self] chord in
                lock.withLock {
                    _keyLog.append(KeyOperation(kind: .press, chord: chord))
                    return _postKeystrokeResult
                }
            },
            postKeyDown: { [self] chord in
                lock.withLock {
                    _keyLog.append(KeyOperation(kind: .down, chord: chord))
                    return _postKeyDownResult
                }
            },
            postKeyUp: { [self] chord in
                lock.withLock {
                    _keyLog.append(KeyOperation(kind: .up, chord: chord))
                    return _postKeyUpResult
                }
            },
            launchApp: { [self] bundleID in
                lock.withLock {
                    _nonKeyboardLog.append(.launchApp(bundleID))
                    return _launchAppResult
                }
            },
            openURL: { [self] string in
                lock.withLock {
                    _nonKeyboardLog.append(.openURL(string))
                    return _openURLResult
                }
            },
            // Code review 2026-08-27, Finding 4 / item (e): `runShortcut`/`focusTextInput`/
            // `switchApp` are `async` on `ActionEnvironment` now (see that type's doc comments).
            // Nothing here actually needs to `await` anything — the spy still just records into
            // the lock-guarded log and returns the matching `*Result` flag synchronously — so
            // these three closures are async purely to satisfy the type; see
            // `Tests/TacitTests/README.md`'s final section for why no test needed to change.
            runShortcut: { [self] name in
                lock.withLock {
                    _nonKeyboardLog.append(.runShortcut(name))
                    return _runShortcutResult
                }
            },
            focusTextInput: { [self] in
                lock.withLock {
                    _nonKeyboardLog.append(.focusTextInput)
                    return _focusTextInputResult
                }
            },
            switchApp: { [self] direction in
                lock.withLock {
                    _nonKeyboardLog.append(.switchApp(direction))
                    return _switchAppResult
                }
            },
            isAccessibilityTrusted: { [self] in
                lock.withLock { _isAccessibilityTrusted }
            }
        )
    }
}
