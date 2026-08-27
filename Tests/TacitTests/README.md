# `TacitTests` — harness for testing `Sources/Tacit/TacitEngine.swift`

Built for code review 2026-08-27, Finding 2 / item (d), steps 1–3 (target + injection + spy) plus
one smoke test proving the seam. **The seven invariant tests from the review's task breakdown are
NOT in this target yet** — three agents write those next, against exactly the API documented
below. This file is their brief. If something here is ambiguous, that's a bug in this file, not a
question to guess past.

## The one-paragraph mental model

`TacitEngine.init` now takes an `actionEnvironment: ActionEnvironment` parameter (default
`LiveActionEnvironment.make()`, so the real app is unaffected) and a `mappingStore: MappingStore`
parameter (default `MappingStore()`, likewise unaffected). Tests supply an
`ActionEnvironmentSpy`-backed environment and an isolated `MappingStore`, bind a gesture to an
action, call `engine.handleFire(_:)` (or another now-internal engine method — see "What's still
private" below) directly — bypassing the camera/Vision/arbitration pipeline entirely — and then
read the spy's ordered logs.

## Constructing an engine with the spy

```swift
import Testing
import TacitCore
@testable import Tacit

@MainActor
@Test func example() {
    let spy = ActionEnvironmentSpy()                      // isAccessibilityTrusted defaults to true
    let mappingStore = TacitTestSupport.isolatedMappingStore()
    let chord = KeyChord(keyCode: 8, modifiers: [.command])  // ⌘C

    mappingStore.setBinding(GestureBinding(enabled: true, action: .keystroke(chord)), for: .thumbIndexTap)

    let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

    engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))

    #expect(spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .press, chord: chord)])
}
```

This is verbatim `Tests/TacitTests/SmokeTests.swift` (minus its comments) — copy it as your
starting point.

**Always mark the test function (or its enclosing suite) `@MainActor`.** `TacitEngine` is a
`@MainActor final class`; every one of its properties and methods — including `handleFire(_:)` —
is main-actor-isolated. A test that omits `@MainActor` won't compile once it touches the engine.

**Always use `TacitTestSupport.isolatedMappingStore()`, never `MappingStore()`.** The bare
default reads/writes the real `~/Library/Application Support/Tacit/mappings.json` on whatever
machine runs the tests, and a v1→v2 migration / defaults-revision top-up chain runs the first
time any `MappingStore` is constructed with no file present — you do not want that racing with (or
polluting) a real install, or with other tests' isolated stores. `isolatedMappingStore()` gives
each test a private temp directory and a private `UserDefaults` suite; nothing it does is
observable outside that one test.

## Driving a gesture through the engine to `handleFire`

`handleFire(_ event: GestureEvent)` was `private`; it is now internal (default access — no
modifier), specifically so `@testable import Tacit` can call it directly. **This is the concrete
call:**

```swift
engine.handleFire(GestureEvent(gesture: someGestureID, timestamp: someDouble))
```

`GestureEvent(gesture:timestamp:)` is a public `TacitCore` init — `timestamp` isn't read by
anything `handleFire` touches (it flows into `GestureEvent`'s own equality/logging only), so `0`
is fine unless your test cares about a specific value.

`handleFire` looks up `event.gesture`'s CURRENT binding in `engine.mappingStore` — set the binding
with `mappingStore.setBinding(_:for:)` *before* calling `handleFire`, not after. From there it
replays the exact same branching `TacitEngine.swift` documents at `handleFire`'s definition
(review file/line references are for the pre-(d) file; search for `MARK: - Closing the loop` in
`TacitEngine.swift` — it's a stable landmark):

| Binding on `event.gesture` | What happens | Where to look |
|---|---|---|
| disabled, or `action == nil` | no-op, nothing logged to the spy | — |
| `.toggleKeystroke`, gesture IS in `TacitEngine.holdableGestures` (`.indexPoint`/`.thumbsUp`/`.victory`) | no-op here — a holdable gesture's toggle fires from the (still-`private`) hold path instead, never from `handleFire` | see "What's still private" |
| `.toggleKeystroke`, gesture NOT holdable | routes to `handleToggleFire`, which engages/releases/swaps the latch and posts `postKeyDown`/`postKeyUp` **synchronously** | `keyLog` gets `.down`/`.up` entries in call order |
| `.holdKeystroke`, gesture IS holdable | no-op here — same reasoning as the toggle row above | see "What's still private" |
| `.holdKeystroke`, gesture NOT holdable (a momentary gesture bound to a hold action with no hold behind it) | falls through to `ActionDispatcher.dispatch`'s full-press fallback: `postKeyDown` then `postKeyUp`, synchronously | `keyLog` gets `.down` then `.up` |
| `.keystroke` | `ActionDispatcher.dispatch` calls `postKeystroke` once, synchronously | `keyLog` gets one `.press` entry |
| `.launchApp` / `.openURL` / `.runShortcut` / `.focusTextInput` / `.switchApp` | dispatched from a `Task.detached` — **not synchronous with the `handleFire` call returning** | `nonKeyboardLog` gets the entry, but only after the detached task runs — see "Awaiting the detached branch" below |

Every one of `.keystroke`/`.holdKeystroke`/`.toggleKeystroke` (the middle three rows above) is
fully synchronous: by the time `engine.handleFire(_:)` returns, `spy.keyLog` already has every
entry that fire is going to produce. No `await`, no `Task.sleep`, no polling needed for those.

### Awaiting the detached branch

The five actions in the last row (`.launchApp`/`.openURL`/`.runShortcut`/`.focusTextInput`/
`.switchApp`) are dispatched from `Task.detached` and are NOT guaranteed to have run their
closure by the time `handleFire(_:)` returns. If a test needs to assert on `nonKeyboardLog` for
one of these, either:

- poll with a short `Task.sleep` loop until `spy.nonKeyboardLog.count` reaches the expected count
  (bounded, e.g. `for _ in 0..<50 { if !spy.nonKeyboardLog.isEmpty { break }; try? await
  Task.sleep(for: .milliseconds(10)) }`), or
- prefer the synchronous three actions above wherever a test's invariant doesn't specifically need
  one of these five — most of the seven invariants (see the review's task breakdown) are about the
  keystroke/hold/toggle paths, which don't have this problem.

This is exactly why the spy is thread-safe (see `ActionEnvironmentSpy`'s own doc comment): a
detached task's closure can run on a different thread than the main-actor test that's polling it.

## Reading the ordered log

`ActionEnvironmentSpy.keyLog: [KeyOperation]` — oldest first, `Equatable`. Each element is
`KeyOperation(kind: KeyOperationKind, chord: KeyChord)`, where `KeyOperationKind` is `.down` /
`.up` / `.press`:

- `.press` — one `postKeystroke` call (a `.keystroke` action's normal fire).
- `.down` / `.up` — one `postKeyDown`/`postKeyUp` call each (hold begin/end, toggle engage/
  release/swap, and the `.holdKeystroke`/`.toggleKeystroke` full-press fallback).

```swift
#expect(spy.keyLog == [
    .init(kind: .down, chord: fnChord),
    .init(kind: .up, chord: fnChord),
])
```

For the "every `postKeyDown` is followed by exactly one `postKeyUp` of the same chord" invariant,
filter `keyLog` by `kind` and zip:

```swift
let downs = spy.keyLog.filter { $0.kind == .down }.map(\.chord)
let ups   = spy.keyLog.filter { $0.kind == .up }.map(\.chord)
#expect(downs == ups)   // same chords, same order — pairing AND ordering in one assertion
```

`ActionEnvironmentSpy.nonKeyboardLog: [NonKeyboardOperation]` — oldest first, `Equatable`, one
case per non-keyboard closure: `.launchApp(String)`, `.openURL(String)`, `.runShortcut(String)`,
`.focusTextInput`, `.switchApp(AppSwitchDirection)`.

`spy.clearLogs()` empties both logs in place without touching `isAccessibilityTrusted` or any
`*Result` flag — use it to isolate two phases of one test (e.g. assert the engage, clear, then
assert the release in isolation).

## Flipping Accessibility trust mid-test

```swift
let spy = ActionEnvironmentSpy(isAccessibilityTrusted: true)   // or set spy.isAccessibilityTrusted later
// ... engage a toggle while trusted ...
spy.isAccessibilityTrusted = false
// ... fire the toggle again; the release path is UNGATED by design (see
//     handleToggleFire's doc comment in TacitEngine.swift) and must still post the key-up ...
```

`isAccessibilityTrusted` is a get/set computed property on the spy, backed by the same `NSLock`
every other field uses. Safe to flip at any point in a test, including between two calls to
`engine.handleFire(_:)`.

## Simulating a failed post

Each keyboard/non-keyboard operation has a matching `*Result: Bool` flag (default `true`):
`postKeystrokeResult`, `postKeyDownResult`, `postKeyUpResult`, `launchAppResult`, `openURLResult`,
`runShortcutResult`, `focusTextInputResult`, `switchAppResult`. Set one `false` *before* firing to
make that closure report failure and drive `ActionDispatcher.dispatch`'s `.failed(_:)` path (or,
for the hold/toggle direct-call paths, whatever `TacitEngine` does when `postKeyDown`/`postKeyUp`
itself returns `false` — see e.g. `handleHoldBegan`'s doc comment).

## The exact spy API (verbatim)

```swift
public final class ActionEnvironmentSpy: @unchecked Sendable {
    public enum KeyOperationKind: String, Equatable, Sendable { case down, up, press }

    public struct KeyOperation: Equatable, Sendable {
        public let kind: KeyOperationKind
        public let chord: KeyChord
        public init(kind: KeyOperationKind, chord: KeyChord)
    }

    public enum NonKeyboardOperation: Equatable, Sendable {
        case launchApp(String)
        case openURL(String)
        case runShortcut(String)
        case focusTextInput
        case switchApp(AppSwitchDirection)
    }

    public init(isAccessibilityTrusted: Bool = true)

    public var keyLog: [KeyOperation] { get }
    public var nonKeyboardLog: [NonKeyboardOperation] { get }
    public func clearLogs()

    public var isAccessibilityTrusted: Bool { get set }
    public var postKeystrokeResult: Bool { get set }
    public var postKeyDownResult: Bool { get set }
    public var postKeyUpResult: Bool { get set }
    public var launchAppResult: Bool { get set }
    public var openURLResult: Bool { get set }
    public var runShortcutResult: Bool { get set }
    public var focusTextInputResult: Bool { get set }
    public var switchAppResult: Bool { get set }

    public func makeEnvironment() -> ActionEnvironment
}
```

Defined in `Tests/TacitTests/ActionEnvironmentSpy.swift`. It is thread-safe (`NSLock`-guarded)
because, unlike `Tests/TacitCoreTests/ActionDispatcherTests.swift`'s spy, calls into it are NOT
guaranteed single-threaded — see that file's top doc comment for why.

`TacitTestSupport.isolatedMappingStore() -> MappingStore` is defined in
`Tests/TacitTests/TestSupport.swift`, `@MainActor`-isolated (matching `MappingStore` itself).

## What's still `private` (not this pass's job — yours)

Steps 1–3 of item (d) only widened what the ONE smoke test needed: `handleFire(_:)`. The review's
other invariants need more of `TacitEngine`'s internals reachable. As of this pass, these are
still `private` in `Sources/Tacit/TacitEngine.swift`:

| Method | Needed for | Signature |
|---|---|---|
| `handleHoldEvent(_:)` | hold-began/hold-ended invariants (drives `handleHoldBegan`/`handleHoldEnded`) | `private func handleHoldEvent(_ event: GestureHoldEvent)` |
| `handleCaptureStateChange(_:)` | "hold began → capture pause → key-up fires" | `private func handleCaptureStateChange(_ state: CaptureState)` |
| `handleApplicationWillTerminate()` | "`handleApplicationWillTerminate` releases both a live hold and a live latch" | `private func handleApplicationWillTerminate()` |

If your invariant needs one of these, widen it the same way `handleFire` was widened: delete the
`private` keyword (default access is `internal`, which `@testable import Tacit` exposes) and add a
one-line doc comment noting which invariant/agent needs it — do not make it `public`, and don't
change its parameter/return types. This is a pure visibility change; it does not alter behavior,
and the shipped app's only call site for each of these stays exactly what it was.

One caveat worth knowing before you rely on it: "hold began → screen lock → key-up fires" (the
review's third invariant) is NOT reachable by simulating the real `com.apple.screenIsLocked`
distributed notification — `handleScreenLockSignal()` (also private) guards on
`case .running = capture.state`, and `capture` is a real, un-injected `CaptureEngine` that never
reaches `.running` without an actual camera session. The two paths that mattered to Finding 3's
stuck-key audit — capture pausing for ANY reason, and a hold ending — both funnel through
`endActiveHoldIfNeeded()` (also private) regardless of which signal triggered them; that shared
chokepoint, not the screen-lock notification itself, is what's actually testable here. Widen
`endActiveHoldIfNeeded()` too if you need it, and consider testing the screen-lock invariant
functionally (call the chokepoint directly) rather than literally (post the real notification).

## What item (e) will change under you

Item (e) (Finding 4, sequenced last per `EXECUTION-LOG.md`) makes `ActionDispatcher.dispatch(_:)`
`async` and three `ActionEnvironment` closures (`runShortcut`, `focusTextInput`, `switchApp`)
`async`. `postKeystroke`/`postKeyDown`/`postKeyUp` stay synchronous (that's the whole point of
Finding 5 / item (c) — ordering depends on them staying synchronous). When that lands:

- `ActionEnvironmentSpy.makeEnvironment()`'s `runShortcut`/`focusTextInput`/`switchApp` closures
  will need to become `async` (drop the immediate `return`, `await` nothing extra — they still
  just record-and-return).
- `TacitEngine.handleFire`'s `.launchApp`/`.openURL`/`.runShortcut`/`.focusTextInput`/`.switchApp`
  branch calls `actionDispatcher.dispatch(action)` from inside `Task.detached`; that call becomes
  `await actionDispatcher.dispatch(action)`. Nothing about how a TEST calls `handleFire(_:)`
  changes — `handleFire` itself is not `async` — but the "Awaiting the detached branch" polling
  advice above becomes even more clearly the pattern to use for those five actions specifically,
  since now there are two async hops (`Task.detached` + the `await dispatch`) instead of one.
- `postKeystroke`/`postKeyDown`/`postKeyUp` and everything this README says about them —
  synchronous, no polling needed — is UNCHANGED by item (e). If your invariant test only touches
  those three, item (e) landing should not require touching your test at all.
