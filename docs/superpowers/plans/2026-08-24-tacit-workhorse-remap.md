# Workhorse Remap + Dictation Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the user's daily workflow actions on the static resting-hand *workhorse* gestures (the most reliable detectors), turn every dynamic gesture off by default, and add a hands-free dictation **toggle** (latched Fn) on a second workhorse — migrating existing installs without clobbering anything the user customized.

**Architecture:** A new `TacitAction.toggleKeystroke(KeyChord)` case (first fire posts key-down and latches; next fire posts key-up), backed by a pure, testable `KeyLatch` state machine in `TacitCore` and wired into `TacitEngine` exactly like `.holdKeystroke` (synchronous main-actor key posting, an explicit release-path inventory). `MappingStore` gains a small **defaults-revision chain** replacing the M3 one-shot bool flag: each revision lists `(old default → new default)` per gesture, and only bindings still *exactly equal* to the old default are rewritten. Library binder grows a Press / Hold / Toggle mode; the popover shows a "Release Fn" safety row while latched.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Combine, `CGEvent` key posting (existing `ActionEnvironment`), `swift test` via `scripts/test.sh`, app bundle via `scripts/make-app.sh`.

**Spec:** `docs/superpowers/specs/2026-08-23-tacit-design.md` — §3.5 (ActionDispatcher), §3.6 (MappingStore defaults; **this plan amends it**, Task 3), §4 (UI binding rules), §6 (trust: fail toward paused-and-saying-so). Product decisions ruled by the user on 2026-08-24 (recorded here because the spec predates them): *"trio, plus copy/paste, plus undo/redo on the workhorses — the others off for now"*, *"Fn hold is right, but also map another easy gesture for toggling"*.

## Global Constraints

- Swift 6 strict concurrency; `TacitCore` stays Foundation-only (no AppKit/ApplicationServices imports there).
- Tests: Swift Testing (`@Test`, `#expect`), run with `./scripts/test.sh` (sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Baseline: **248 tests green** at `db3aad8`. Every task ends green.
- Commit per task with the repo's prefix style (`feat:` / `fix:` / `docs:`), and push `main` (repo is `breton-studio/tacit`, public; pushing main after each task is the established convention here).
- UI (spec §4): near-monochrome, ONE accent only for armed/active state; system font; motion via `TacitMotion` tokens only (never magic numbers); 44pt minimum hit targets (`.frame(minHeight: 44)`); plain-verb copy ("Release Fn", not "Deactivate latch"); reuse `TacitToggleStyle`, `TacitButtonStyle`, `TacitUtilityRowButtonStyle` — no new styles.
- Stuck-key impossibility (M3 Task 9 invariant, keep it): every `postKeyDown` is paired with exactly one `postKeyUp` on **every** exit path; key posts happen **synchronously on the main actor** (never `Task.detached`) so down/up ordering is structural.
- Reserved gestures `looseFist`/`openPalm` stay reserved (enabled, unbindable).
- Wire format `mappings.json` stays `version: 2` — adding an enum case is Codable-additive. (An *older* build reading a file containing `toggleKeystroke` would quarantine it and fall back to defaults; downgrade isn't a supported path — say so in the `TacitAction` doc comment.)
- `GestureID` and `GestureCatalog` are unchanged by this plan.

## The new defaults (revision 3) — exact values

| Gesture | Old default (rev 2) | New default (rev 3) |
|---|---|---|
| `thumbIndexTap` | enabled, ⌘C `KeyChord(keyCode: 8, modifiers: [.command])` | unchanged |
| `thumbMiddleTap` | enabled, ⌘V `KeyChord(keyCode: 9, modifiers: [.command])` | unchanged |
| `victory` | enabled, ⌃Tab `KeyChord(keyCode: 48, modifiers: [.control])` | enabled, **⌘Tab** `KeyChord(keyCode: 48, modifiers: [.command])` |
| `thumbsUp` | enabled, Return `KeyChord(keyCode: 36, modifiers: [])` | enabled, **`.focusTextInput`** |
| `thumbSwipeBackward` | enabled, ⌘Z `KeyChord(keyCode: 6, modifiers: [.command])` | unchanged |
| `thumbSwipeForward` | enabled, ⇧⌘Z `KeyChord(keyCode: 6, modifiers: [.command, .shift])` | unchanged |
| `indexPoint` | enabled, `.holdKeystroke(KeyChord(keyCode: 63, modifiers: []))` (Fn) | unchanged |
| `thumbRingPinkyTap` | disabled, `nil` | enabled, **`.toggleKeystroke(KeyChord(keyCode: 63, modifiers: []))`** |
| `swipeRight` | enabled, ⌘Tab | **disabled**, suggestion ⌃→ `KeyChord(keyCode: 124, modifiers: [.control])` |
| `swipeUp` | enabled, `.focusTextInput` | **disabled**, suggestion ⌃↑ `KeyChord(keyCode: 126, modifiers: [.control])` |
| everything else | as today | unchanged |

Enabled set after this plan (fresh install): `thumbIndexTap, thumbMiddleTap, victory, thumbsUp, thumbSwipeBackward, thumbSwipeForward, indexPoint, thumbRingPinkyTap` (8 user bindings) + `looseFist, openPalm` (2 reserved) = 10.

## Rulings (lead decisions; executors follow them, reviewers hold the diff to them)

1. **Toggle is app-agnostic latching**, not a Wispr-Flow-specific hotkey: the latch simply holds Fn down until the next tap, which any push-to-talk app reads as a continuous hold. Cost if wrong: user wants a different toggle mechanism — the action type is rebindable in the binder.
2. **The latch survives clutch disarm and command-window expiry** (hands-free is the whole point), and is released ONLY by: (a) the next fire of a `.toggleKeystroke` binding (same chord → release; different chord → release old, engage new), (b) capture stopping for any reason — master toggle off, "Pause for an Hour", screen lock, display sleep, camera unavailable (`handleCaptureStateChange`, the same chokepoint holds use), (c) app quit (`handleApplicationWillTerminate`), (d) the latched gesture's binding changing so it is no longer `enabled` + `.toggleKeystroke(sameChord)` (rebind/disable in the Library), (e) the popover's "Release Fn" row. Cost if wrong: a latched key persists longer than the user expected — the popover row is the always-visible escape hatch.
3. **Hold ↔ latch interplay:** while chord X is latched, a `.holdKeystroke(X)` hold's `began` is a no-op (key is already down) and its `ended` is therefore also a no-op (no `activeHoldChord` was set). A hold of a *different* chord is unaffected. Cost if wrong: none observable — Fn stays down either way.
4. **HUD copy for the toggle** reuses the existing gesture chip: "<Gesture> → Fn on" / "<Gesture> → Fn off" on user-initiated toggles only (tap or popover row). Safety releases (b)/(c)/(d) are silent — the surface that caused them (pause, lock, Library edit) is already the feedback. Cost if wrong: slightly under-communicated auto-release; spec §6 trust is still met by the popover row disappearing.
5. **Defaults-revision chain replaces the bool flag.** `UserDefaults` key `tacit.defaultsRevision` (Int). Migration of the old flag: `tacit.workflowDefaultsApplied == true` and no revision key ⇒ treat as revision 2; neither key ⇒ revision 0 (pre-M3 install, gets rev 2 then rev 3 applied in order). A store whose `mappings.json` did not exist (fresh install) stamps `currentDefaultsRevision` directly and applies nothing. Cost if wrong: an existing install misses a top-up — the user rebinds in the Library.
6. **Binder mode UI** is a three-segment `Picker` ("Press", "Hold", "Toggle") with `.pickerStyle(.segmented)` replacing the "Hold instead of press" `Toggle` — same style as the `Action type` picker directly above it. Cost if wrong: a slightly denser card; no behavior risk.

## File Structure

- Modify `Sources/TacitCore/TacitAction.swift` — add `case toggleKeystroke(KeyChord)`, `requiresAccessibility`, `summary`.
- Modify `Sources/TacitCore/ActionDispatcher.swift` — `.toggleKeystroke` fire-path fallback (full press, mirrors `.holdKeystroke`).
- Create `Sources/TacitCore/KeyLatch.swift` — pure latch state machine (`KeyLatch`, `LatchedKey`, `LatchTransition`).
- Modify `Sources/TacitCore/MappingStore.swift` — rev-3 `defaultBindings()`, `DefaultsRevision` chain, remove the M3 bool-flag top-up.
- Modify `Sources/Tacit/TacitEngine.swift` — toggle fire path, latch release inventory, `latchedChord` published, `releaseLatch()`.
- Modify `Sources/Tacit/PopoverView.swift` — "Release Fn" row while latched.
- Modify `Sources/Tacit/Library/ActionBinders.swift` — `KeystrokeMode` picker, `ActionKind` mapping.
- Modify `docs/superpowers/specs/2026-08-23-tacit-design.md` §3.5/§3.6, `README.md` run paragraph.
- Tests: `Tests/TacitCoreTests/ActionDispatcherTests.swift`, create `Tests/TacitCoreTests/KeyLatchTests.swift`, `Tests/TacitCoreTests/MappingStoreTests.swift`.

---

### Task 1: `TacitAction.toggleKeystroke` + dispatcher fallback

**Files:**
- Modify: `Sources/TacitCore/TacitAction.swift:21-54`
- Modify: `Sources/TacitCore/ActionDispatcher.swift:87-102` (add a case after `.holdKeystroke`)
- Test: `Tests/TacitCoreTests/ActionDispatcherTests.swift`

**Interfaces:**
- Produces: `TacitAction.toggleKeystroke(KeyChord)`; `requiresAccessibility == true`; `summary == "Toggle " + chord.display` (so keyCode 63 renders "Toggle Fn" via `KeyChord.capNames`). `ActionDispatcher.dispatch(.toggleKeystroke(c))` performs a full press (down then up) — the fallback for any non-engine caller; `TacitEngine` (Task 4) never routes toggles through `dispatch`.

- [ ] **Step 1: Write the failing tests** — append to `Tests/TacitCoreTests/ActionDispatcherTests.swift`:

```swift
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
```

Then copy the four existing hold-fallback dispatch tests at `ActionDispatcherTests.swift:192-246` (`dispatchHoldKeystrokeCallsPostKeyDownAndPostKeyUpWhenTrusted`, `dispatchHoldKeystrokeFullPressPostsDownBeforeUp`, `dispatchHoldKeystrokeReturnsNeedsAccessibilityWithoutPostingWhenUntrusted`, `dispatchHoldKeystrokeFailsWhenPostKeyDownFails`) verbatim, renaming `HoldKeystroke` → `ToggleKeystroke` in each test name and replacing every `.holdKeystroke(` with `.toggleKeystroke(` in the bodies. Same `Spy`/`makeDispatcher` helpers, same assertions.

Also extend `tacitActionCodableRoundTrips` (line 32): add `.toggleKeystroke(KeyChord(keyCode: 63, modifiers: []))` to its `actions` array, and `requiresAccessibilityIsTrueOnlyForKeystrokeHoldKeystrokeAndFocusTextInput` (line 7): add a `#expect(... .toggleKeystroke(...).requiresAccessibility == true)` line.

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter ActionDispatcherTests`
Expected: compile error `type 'TacitAction' has no member 'toggleKeystroke'`.

- [ ] **Step 3: Implement** — in `TacitAction.swift`, after the `holdKeystroke` case:

```swift
    /// Workhorse-remap plan, Task 1: a keystroke LATCHED by one fire and released by the next —
    /// key-down on the first fire of a gesture bound to this action, key-up on the following fire
    /// (of the same chord). Hands-free push-to-talk: with Fn latched, a dictation app that treats
    /// Fn as "hold to talk" keeps listening until the user taps the gesture again. The latch is
    /// owned by `TacitEngine` (`KeyLatch`), which routes this case's down/up lifecycle directly to
    /// `ActionEnvironment.postKeyDown`/`postKeyUp` — never through `ActionDispatcher.dispatch(_:)`.
    /// `dispatch(_:)` still handles a bare fire of this action (a non-engine caller with no latch
    /// behind it) by falling back to a full press — down then up — exactly like `.holdKeystroke`.
    /// Codable via synthesis: additive for old `mappings.json` files. An OLDER build reading a
    /// file that contains this case fails to decode it and quarantines the file (downgrade is not
    /// a supported path).
    case toggleKeystroke(KeyChord)
```

Update `requiresAccessibility`:

```swift
        case .keystroke, .holdKeystroke, .toggleKeystroke, .focusTextInput: true
```

Update `summary`:

```swift
        case .toggleKeystroke(let chord): "Toggle " + chord.display
```

In `ActionDispatcher.swift`, after the `.holdKeystroke` case body (before `case .launchApp`):

```swift
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
```

Update the doc comment on `dispatch(_:)` that lists the gated cases (`ActionDispatcher.swift:70`) to include `.toggleKeystroke`.

- [ ] **Step 4: Build the app target too** (it has exhaustive switches over `TacitAction`): run `./scripts/test.sh` (whole suite). Expected: a compile error in `Sources/Tacit/Library/ActionBinders.swift` `ActionKind.init` (switch not exhaustive). Fix minimally now so the build is green — at `ActionBinders.swift:159`:

```swift
        case .none, .keystroke, .holdKeystroke, .toggleKeystroke: self = .keystroke
```

(Task 5 replaces this binder's hold toggle with a mode picker; this one-line change just keeps the build green.)

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test.sh`
Expected: all green, 248 + 7 new tests.

- [ ] **Step 6: Commit + push**

```bash
git add Sources/TacitCore/TacitAction.swift Sources/TacitCore/ActionDispatcher.swift Sources/Tacit/Library/ActionBinders.swift Tests/TacitCoreTests/ActionDispatcherTests.swift
git commit -m "feat: toggleKeystroke action (latched key) with full-press dispatch fallback"
git push origin main
```

---

### Task 2: `KeyLatch` state machine

**Files:**
- Create: `Sources/TacitCore/KeyLatch.swift`
- Test: create `Tests/TacitCoreTests/KeyLatchTests.swift`

**Interfaces:**
- Produces (used by Task 4):

```swift
public struct LatchedKey: Equatable, Sendable { public let gesture: GestureID; public let chord: KeyChord }
public enum LatchTransition: Equatable, Sendable {
    case engaged(KeyChord)                                   // post key-down
    case released(KeyChord)                                  // post key-up
    case swapped(released: KeyChord, engaged: KeyChord)      // post key-up(released) THEN key-down(engaged)
}
public struct KeyLatch: Equatable, Sendable {
    public private(set) var active: LatchedKey?
    public init()
    public mutating func toggle(gesture: GestureID, chord: KeyChord) -> LatchTransition
    public mutating func release() -> KeyChord?              // nil if nothing latched
    public func isLatched(_ chord: KeyChord) -> Bool
}
```

- [ ] **Step 1: Write the failing tests** — `Tests/TacitCoreTests/KeyLatchTests.swift`:

```swift
import Testing
@testable import TacitCore

private let fn = KeyChord(keyCode: 63, modifiers: [])
private let cmdSpace = KeyChord(keyCode: 49, modifiers: [.command])

@Test func freshLatchHasNothingActive() {
    let latch = KeyLatch()
    #expect(latch.active == nil)
    #expect(latch.isLatched(fn) == false)
    var mutable = latch
    #expect(mutable.release() == nil)
}

@Test func firstToggleEngagesAndRecordsGestureAndChord() {
    var latch = KeyLatch()
    #expect(latch.toggle(gesture: .thumbRingPinkyTap, chord: fn) == .engaged(fn))
    #expect(latch.active == LatchedKey(gesture: .thumbRingPinkyTap, chord: fn))
    #expect(latch.isLatched(fn) == true)
    #expect(latch.isLatched(cmdSpace) == false)
}

@Test func secondToggleOfSameChordReleases() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .thumbRingPinkyTap, chord: fn) == .released(fn))
    #expect(latch.active == nil)
}

@Test func sameChordFromADifferentGestureStillReleases() {
    // Two gestures bound to Toggle Fn are one latch: either can end it.
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .victory, chord: fn) == .released(fn))
    #expect(latch.active == nil)
}

@Test func toggleOfADifferentChordSwapsReleasingTheOldFirst() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .victory, chord: cmdSpace) == .swapped(released: fn, engaged: cmdSpace))
    #expect(latch.active == LatchedKey(gesture: .victory, chord: cmdSpace))
}

@Test func releaseReturnsTheLatchedChordExactlyOnce() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.release() == fn)
    #expect(latch.release() == nil)
    #expect(latch.active == nil)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test.sh --filter KeyLatchTests`
Expected: compile error `cannot find 'KeyLatch' in scope`.

- [ ] **Step 3: Implement** — `Sources/TacitCore/KeyLatch.swift`:

```swift
import Foundation

/// The key a `.toggleKeystroke` fire has latched down, and which gesture did it.
public struct LatchedKey: Equatable, Sendable {
    public let gesture: GestureID
    public let chord: KeyChord

    public init(gesture: GestureID, chord: KeyChord) {
        self.gesture = gesture
        self.chord = chord
    }
}

/// What the caller must post after a `KeyLatch.toggle` — the latch itself never touches the
/// keyboard. Ordering inside `.swapped` matters: release the old chord BEFORE engaging the new
/// one, so at most one latched key is ever down.
public enum LatchTransition: Equatable, Sendable {
    case engaged(KeyChord)
    case released(KeyChord)
    case swapped(released: KeyChord, engaged: KeyChord)
}

/// Pure state for `.toggleKeystroke`: at most ONE chord is latched at a time. `toggle` with the
/// currently latched chord releases it (regardless of which gesture asks); `toggle` with a
/// different chord swaps. `release()` is the forced path every safety exit uses (capture stopped,
/// app quit, binding changed, popover "Release" row) — it hands back the chord to key-up, exactly
/// once, or `nil` when nothing was latched. Mirrors `HoldTracker`'s design: the engine owns the
/// key posting; this type only decides.
public struct KeyLatch: Equatable, Sendable {
    public private(set) var active: LatchedKey?

    public init() {}

    public mutating func toggle(gesture: GestureID, chord: KeyChord) -> LatchTransition {
        guard let current = active else {
            active = LatchedKey(gesture: gesture, chord: chord)
            return .engaged(chord)
        }
        if current.chord == chord {
            active = nil
            return .released(chord)
        }
        active = LatchedKey(gesture: gesture, chord: chord)
        return .swapped(released: current.chord, engaged: chord)
    }

    public mutating func release() -> KeyChord? {
        defer { active = nil }
        return active?.chord
    }

    public func isLatched(_ chord: KeyChord) -> Bool {
        active?.chord == chord
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test.sh --filter KeyLatchTests`
Expected: 6 passed.

- [ ] **Step 5: Commit + push**

```bash
git add Sources/TacitCore/KeyLatch.swift Tests/TacitCoreTests/KeyLatchTests.swift
git commit -m "feat: KeyLatch state machine for toggled keystrokes"
git push origin main
```

---

### Task 3: Revision-3 defaults + defaults-revision chain in `MappingStore` (+ spec §3.6 amendment)

**Files:**
- Modify: `Sources/TacitCore/MappingStore.swift:73-84` (version doc), `:96-113` (init), `:117-136` (load), `:186-244` (replace the M3 top-up block), `:266-343` (`defaultBindings`)
- Modify: `docs/superpowers/specs/2026-08-23-tacit-design.md:86` (§3.6 defaults sentence) and `:80` (§3.5 conformer list)
- Test: `Tests/TacitCoreTests/MappingStoreTests.swift`

**Interfaces:**
- Produces: `MappingStore.defaultBindings()` returns the **rev-3 table** above. `MappingStore.currentDefaultsRevision: Int = 3`. `UserDefaults` key `"tacit.defaultsRevision"` (Int). Internal (`internal` visibility for tests via `@testable`): `static let defaultsRevisions: [DefaultsRevision]` where

```swift
struct DefaultsRevision: Sendable {
    let revision: Int
    /// gesture → (what an untouched binding looks like before this revision, what it becomes)
    let changes: [GestureID: (old: GestureBinding, new: GestureBinding)]
}
```

- Consumes: `TacitAction.toggleKeystroke` (Task 1).

- [ ] **Step 1: Rewrite the default-pinning tests** in `MappingStoreTests.swift`. Replace the bodies of these three tests (lines 23–72) and the file-level constant:

```swift
private let defaultsRevisionKey = "tacit.defaultsRevision"
private let legacyWorkflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

private let fn = KeyChord(keyCode: 63, modifiers: [])

// MARK: - First launch defaults (revision 3: workhorse remap)

@MainActor
@Test func firstLaunchHasTheWorkhorseCoreEnabledOnTheRevisionThreeDefaults() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())

    #expect(store.binding(for: .thumbIndexTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 8, modifiers: [.command])))) // ⌘C
    #expect(store.binding(for: .thumbMiddleTap) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 9, modifiers: [.command])))) // ⌘V
    #expect(store.binding(for: .victory) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))) // ⌘Tab
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .thumbSwipeBackward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command])))) // ⌘Z
    #expect(store.binding(for: .thumbSwipeForward) ==
        GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 6, modifiers: [.command, .shift])))) // ⇧⌘Z
    #expect(store.binding(for: .indexPoint) == GestureBinding(enabled: true, action: .holdKeystroke(fn)))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

@MainActor
@Test func firstLaunchHasTheDynamicSwipesOffWithSuggestions() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    #expect(store.binding(for: .swipeRight) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])))) // ⌃→
    #expect(store.binding(for: .swipeUp) ==
        GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])))) // ⌃↑
}

@MainActor
@Test func firstLaunchOnlyTheEightWorkhorseBindingsAndTwoReservedAreEnabled() {
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: makeTempUserDefaults())
    let enabledIDs = Set(GestureID.allCases.filter { store.binding(for: $0).enabled })
    let expected: Set<GestureID> = [
        .thumbIndexTap, .thumbMiddleTap, .victory, .thumbsUp, .thumbSwipeBackward, .thumbSwipeForward,
        .indexPoint, .thumbRingPinkyTap,
        .looseFist, .openPalm,
    ]
    #expect(enabledIDs == expected)
}
```

Delete `firstLaunchHasTheWorkflowDefaultsTrioEnabled` (its assertions are now wrong). Keep `firstLaunchReservedGesturesAreEnabledWithNilAction`, `defaultBindingsCoverAllTwentyThreeGestureIDs`, `rotateAndScrollSplitIDsHaveExpectedDisabledDefaults` as they are.

- [ ] **Step 2: Replace the four `topUp…` tests (lines 147–252) with the revision-chain tests:**

```swift
// MARK: - Defaults-revision chain

/// Encodes a v2 file the way a real install wrote it (keys are GestureID rawValues).
private func writeV2File(_ bindings: [String: GestureBinding], in dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("mappings.json")
    try JSONEncoder().encode(V2MappingsFile(version: 2, bindings: bindings)).write(to: url)
    return url
}

private let rev2Victory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control])))
private let rev2ThumbsUp = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: [])))
private let rev2SwipeRight = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
private let rev2SwipeUp = GestureBinding(enabled: true, action: .focusTextInput)
private let rev2RingPinky = GestureBinding(enabled: false, action: nil)

@MainActor
@Test func freshInstallStampsTheCurrentRevisionAndAppliesNoTopUp() {
    let flags = makeTempUserDefaults()
    let store = MappingStore(directory: makeTempDirectory(), userDefaults: flags)
    #expect(flags.integer(forKey: defaultsRevisionKey) == MappingStore.currentDefaultsRevision)
    #expect(store.binding(for: .victory).action == .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
}

/// The core scenario for the user's own install: a rev-2 file (M3 top-up already applied, legacy
/// bool flag set) sitting exactly on the old defaults. Every changed gesture moves to rev 3.
@MainActor
@Test func untouchedRevisionTwoFileIsMovedToRevisionThree() throws {
    let dir = makeTempDirectory()
    let fileURL = try writeV2File([
        "victory": rev2Victory, "thumbsUp": rev2ThumbsUp,
        "swipeRight": rev2SwipeRight, "swipeUp": rev2SwipeUp,
        "thumbRingPinkyTap": rev2RingPinky,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))))
    #expect(store.binding(for: .thumbsUp) == GestureBinding(enabled: true, action: .focusTextInput))
    #expect(store.binding(for: .swipeRight) == GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))))
    #expect(store.binding(for: .swipeUp) == GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))))
    #expect(store.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 3)

    let onDisk = try JSONDecoder().decode(V2MappingsFile.self, from: Data(contentsOf: fileURL))
    #expect(onDisk.version == 2)
    #expect(onDisk.bindings["thumbRingPinkyTap"] == GestureBinding(enabled: true, action: .toggleKeystroke(fn)))
}

/// A customized binding — anything not EXACTLY equal to the old default — is left alone, while
/// its untouched neighbours still move.
@MainActor
@Test func customizedBindingsSurviveTheRevisionThreeTopUp() throws {
    let dir = makeTempDirectory()
    let usersVictory = GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command, .shift]))) // ⇧⌘Tab
    let usersDisabledThumbsUp = GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 36, modifiers: []))) // turned off
    _ = try writeV2File([
        "victory": usersVictory, "thumbsUp": usersDisabledThumbsUp, "swipeRight": rev2SwipeRight,
    ], in: dir)
    let flags = makeTempUserDefaults()
    flags.set(true, forKey: legacyWorkflowDefaultsAppliedKey)

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .victory) == usersVictory)
    #expect(store.binding(for: .thumbsUp) == usersDisabledThumbsUp)
    #expect(store.binding(for: .swipeRight).enabled == false)
}

/// A pre-M3 file (no flag, no revision key) gets revision 2 THEN revision 3, in order: the
/// rev-2 top-up enables swipeRight→⌘Tab, and rev 3 then turns it back off — so the net result
/// equals a fresh rev-3 install for anything the user never touched.
@MainActor
@Test func preM3FileWalksTheWholeChainInOrder() throws {
    let dir = makeTempDirectory()
    _ = try writeV2File([
        "swipeRight": GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))),
        "swipeUp": GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))),
        "indexPoint": GestureBinding(enabled: false, action: nil),
        "victory": rev2Victory,
    ], in: dir)
    let flags = makeTempUserDefaults() // neither key set ⇒ revision 0

    let store = MappingStore(directory: dir, userDefaults: flags)

    #expect(store.binding(for: .indexPoint) == GestureBinding(enabled: true, action: .holdKeystroke(fn)))
    #expect(store.binding(for: .swipeRight).enabled == false)
    #expect(store.binding(for: .swipeUp).enabled == false)
    #expect(store.binding(for: .victory).action == .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
    #expect(flags.integer(forKey: defaultsRevisionKey) == 3)
}

/// Once stamped at the current revision, a later load never re-applies — a user who turns the
/// toggle gesture off afterwards must not see it silently come back.
@MainActor
@Test func topUpNeverReappliesOnceStampedAtCurrentRevision() {
    let dir = makeTempDirectory()
    let flags = makeTempUserDefaults()
    let first = MappingStore(directory: dir, userDefaults: flags)
    first.setBinding(GestureBinding(enabled: false, action: .toggleKeystroke(fn)), for: .thumbRingPinkyTap)

    let second = MappingStore(directory: dir, userDefaults: flags)
    #expect(second.binding(for: .thumbRingPinkyTap) == GestureBinding(enabled: false, action: .toggleKeystroke(fn)))
}
```

`V2MappingsFile` already exists in this test file (used by the old top-up tests at line 180) — keep it.

- [ ] **Step 3: Run to verify they fail**

Run: `./scripts/test.sh --filter MappingStoreTests`
Expected: compile error on `MappingStore.currentDefaultsRevision`, plus failures on the new default values.

- [ ] **Step 4: Implement the rev-3 table** — in `defaultBindings()` (`MappingStore.swift:266-343`) make exactly these edits:
  - `victory`: `KeyChord(keyCode: 48, modifiers: [.command]) // ⌘Tab` (was `[.control]`).
  - `thumbsUp`: `GestureBinding(enabled: true, action: .focusTextInput)`.
  - `thumbRingPinkyTap`: `GestureBinding(enabled: true, action: .toggleKeystroke(KeyChord(keyCode: 63, modifiers: []))) // Toggle Fn — hands-free dictation`.
  - `swipeRight`: `GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))) // ⌃→ suggestion`.
  - `swipeUp`: `GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))) // ⌃↑ suggestion`.
  - Move these two out of the "M3 Task 11 workflow defaults" block into the "Disabled, with a suggested action" block, and rewrite that block's header comment: `// Enabled — M3 Task 11's workflow trio, relocated onto workhorses by the 2026-08-24 remap: app-switch (victory), text-field focus (thumbsUp), hold-to-dictate (indexPoint), toggle-dictate (thumbRingPinkyTap).` Also update the method doc comment ("nine enabled user commands" → "eight enabled user commands").

- [ ] **Step 5: Implement the revision chain** — replace everything from `private static let workflowDefaultsAppliedKey` through the end of `applyWorkflowDefaultsTopUpIfNeeded()` (`MappingStore.swift:186-244`) with:

```swift
    // MARK: - Defaults-revision chain

    /// One step of the defaults history. `changes[id].old` is what a NEVER-TOUCHED binding for
    /// `id` looked like before this revision; `new` is what it becomes. A binding is topped up only
    /// when it is EXACTLY equal to `old` — anything else is the user's own choice and is left alone.
    struct DefaultsRevision: Sendable {
        let revision: Int
        let changes: [GestureID: (old: GestureBinding, new: GestureBinding)]
    }

    /// The revision `defaultBindings()` currently represents. Bump it and append a
    /// `DefaultsRevision` whenever a default VALUE changes for existing users.
    public static let currentDefaultsRevision = 3

    /// `UserDefaults` key holding the revision an install has been topped up to (Int).
    static let defaultsRevisionKey = "tacit.defaultsRevision"
    /// The M3 Task 11 one-shot flag this chain replaces; still read so upgraded installs resume
    /// from revision 2 instead of replaying it.
    static let legacyWorkflowDefaultsAppliedKey = "tacit.workflowDefaultsApplied"

    private static let fnChord = KeyChord(keyCode: 63, modifiers: [])

    static let defaultsRevisions: [DefaultsRevision] = [
        // M3 Task 11: app-switch, focus-input, hold-to-dictate — first shipped on the swipes.
        DefaultsRevision(revision: 2, changes: [
            .swipeRight: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
            ),
            .swipeUp: (
                old: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .focusTextInput)
            ),
            .indexPoint: (
                old: GestureBinding(enabled: false, action: nil),
                new: GestureBinding(enabled: true, action: .holdKeystroke(fnChord))
            ),
        ]),
        // 2026-08-24 workhorse remap: the workflow trio moves onto static resting-hand poses,
        // the dynamic swipes go back to off, and a second workhorse toggles dictation.
        DefaultsRevision(revision: 3, changes: [
            .victory: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.control]))),
                new: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command])))
            ),
            .thumbsUp: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 36, modifiers: []))),
                new: GestureBinding(enabled: true, action: .focusTextInput)
            ),
            .swipeRight: (
                old: GestureBinding(enabled: true, action: .keystroke(KeyChord(keyCode: 48, modifiers: [.command]))),
                new: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 124, modifiers: [.control])))
            ),
            .swipeUp: (
                old: GestureBinding(enabled: true, action: .focusTextInput),
                new: GestureBinding(enabled: false, action: .keystroke(KeyChord(keyCode: 126, modifiers: [.control])))
            ),
            .thumbRingPinkyTap: (
                old: GestureBinding(enabled: false, action: nil),
                new: GestureBinding(enabled: true, action: .toggleKeystroke(fnChord))
            ),
        ]),
    ]

    /// The revision this install was last topped up to: the Int key if present; else 2 if the
    /// legacy M3 bool flag is set; else 0.
    private var storedDefaultsRevision: Int {
        if userDefaults.object(forKey: Self.defaultsRevisionKey) != nil {
            return userDefaults.integer(forKey: Self.defaultsRevisionKey)
        }
        return userDefaults.bool(forKey: Self.legacyWorkflowDefaultsAppliedKey) ? 2 : 0
    }

    /// Walks every revision above `storedDefaultsRevision` in order, rewriting only bindings that
    /// still EXACTLY equal that revision's `old` value, then stamps `currentDefaultsRevision`.
    /// Runs at the end of `init`, after `load()` has settled `bindings`. A fresh install (no file
    /// existed) skips the walk entirely — `defaultBindings()` is already current — and just stamps.
    private func applyDefaultsRevisionsIfNeeded(fileExisted: Bool) {
        defer { userDefaults.set(Self.currentDefaultsRevision, forKey: Self.defaultsRevisionKey) }
        guard fileExisted else { return }
        let stored = storedDefaultsRevision
        guard stored < Self.currentDefaultsRevision else { return }

        var didChange = false
        for step in Self.defaultsRevisions where step.revision > stored {
            for (id, change) in step.changes where binding(for: id) == change.old {
                bindings[id] = change.new
                didChange = true
            }
        }
        if didChange {
            persist()
        }
    }
```

Then make `load()` report whether a file existed and thread it through `init`:

```swift
    /// Returns `true` if a `mappings.json` was present (readable or not), `false` on a fresh install.
    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else {
            persist()
            return false
        }
        // … existing v2 / v1 / recover branches unchanged, each followed by `return true` …
    }
```

and in `init` replace `load(); applyWorkflowDefaultsTopUpIfNeeded()` with:

```swift
        let fileExisted = load()
        applyDefaultsRevisionsIfNeeded(fileExisted: fileExisted)
```

Delete `workflowDefaultsAppliedKey`, `workflowDefaultTopUpIDs`, `oldSuggestedDefaultActions`, and `applyWorkflowDefaultsTopUpIfNeeded()`. Update the `userDefaults` property doc comment (`MappingStore.swift:89-93`) to say it backs the defaults-revision stamp.

- [ ] **Step 6: Run the store tests, then the full suite**

Run: `./scripts/test.sh --filter MappingStoreTests` → all pass. Then `./scripts/test.sh` → all green (the `GestureCatalogTests`/`SmokeTests` must not have pinned the old defaults; if one did, update its expected value to the rev-3 table — the table in this plan is the authority).

- [ ] **Step 7: Amend the spec** — `docs/superpowers/specs/2026-08-23-tacit-design.md`:
  - §3.6 (line 86): replace the sentence starting "Ships with sensible defaults…" with:
    > Ships with sensible defaults from the ergonomics report's example maps, all *disabled* except the workhorse core so first-run is calm (defaults **revision 3**, 2026-08-24): thumb-index tap → ⌘C, thumb-middle tap → ⌘V, victory → ⌘Tab (app switch), thumbs-up → focus text input, thumb-swipe-on-index → undo/redo (⌘Z / ⇧⌘Z), index-point *hold* → Fn (push-to-talk dictation), thumb–ring/pinky tap → *toggle* Fn (hands-free dictation). Every dynamic gesture ships off. Default *values* are versioned separately from the wire format: a `DefaultsRevision` chain rewrites only bindings still exactly equal to the previous default. Loose fist (clutch) and open palm (disarm) are reserved system gestures and cannot be bound.
  - §3.5 (line 80): after the conformer list sentence, add: `Keystrokes come in three modes: *press* (down+up), *hold* (down while a holdable pose is held), and *toggle* (down on one fire, up on the next — a latch owned by the engine, released on any capture stop, quit, or rebind).`

- [ ] **Step 8: Commit + push**

```bash
git add Sources/TacitCore/MappingStore.swift Tests/TacitCoreTests/MappingStoreTests.swift docs/superpowers/specs/2026-08-23-tacit-design.md
git commit -m "feat: workhorse remap defaults (rev 3) with defaults-revision chain"
git push origin main
```

---

### Task 4: Engine wiring — toggle fire path + latch release inventory

**Files:**
- Modify: `Sources/Tacit/TacitEngine.swift` — properties near `:272`, `init` sink at `:331-339`, `handleCaptureStateChange` at `:654-680`, `handleHoldBegan` at `:847-850`, `handleApplicationWillTerminate` at `:936-941`, `handleFire` at `:950-982`.

**Interfaces:**
- Consumes: `KeyLatch`, `LatchedKey`, `LatchTransition` (Task 2); `TacitAction.toggleKeystroke` (Task 1); existing `actionEnvironment.postKeyDown/postKeyUp/isAccessibilityTrusted`, `hudController.show/showError`, `latestFrame`, `isHUDEnabled`, `mappingStore`.
- Produces (used by Task 5): `@Published private(set) var latchedChord: KeyChord?` and `func releaseLatch()` (public within the app target) on `TacitEngine`.

There are no unit tests for the app target (all tests live in `TacitCoreTests`); this task's verification is: it compiles under Swift 6 strict concurrency, the full suite stays green, and the **release-path inventory** below is complete and documented in code the same way `endActiveHoldIfNeeded()`'s inventory is.

- [ ] **Step 1: Add state** — next to `activeHoldChord` (`:272`):

```swift
    /// Workhorse-remap plan, Task 4: the `.toggleKeystroke` latch. Pure state in `TacitCore`;
    /// this engine owns the key posting around it. See `releaseLatchIfNeeded()` for the complete
    /// release-path inventory (the toggle's answer to `endActiveHoldIfNeeded()`).
    private var keyLatch = KeyLatch()
    /// The chord currently latched down via `.toggleKeystroke`, or `nil` — published so the
    /// popover can show its "Release <key>" safety row (Task 5). Mirrors `keyLatch.active?.chord`.
    @Published private(set) var latchedChord: KeyChord?
```

- [ ] **Step 2: Toggle fire path** — in `handleFire(_:)`, immediately after `guard binding.enabled, let action = binding.action else { return }` and BEFORE the `.holdKeystroke` guard, insert:

```swift
        // Workhorse-remap plan, Task 4: `.toggleKeystroke` is engine-owned exactly like
        // `.holdKeystroke` — posted synchronously on the main actor (structural down/up ordering,
        // see `handleHoldBegan(_:)`'s doc comment), never through `ActionDispatcher.dispatch`'s
        // detached full-press fallback, and skipping `applyDispatchOutcome`'s first-fire
        // bookkeeping (the toggle's own HUD line below is the feedback).
        if case .toggleKeystroke(let chord) = action {
            handleToggleFire(gesture: event.gesture, chord: chord)
            return
        }
```

Add the method after `handleHoldEnded(_:)`:

```swift
    /// A fire of a gesture bound to `.toggleKeystroke`. Engages, releases, or swaps the latch and
    /// posts the matching key events synchronously (`.swapped` posts the old chord's up BEFORE the
    /// new chord's down, so at most one latched key is ever down). User-initiated, so it shows
    /// "<Gesture> → <key> on/off" (Ruling 4); the forced releases in `releaseLatchIfNeeded()` are
    /// silent.
    private func handleToggleFire(gesture: GestureID, chord: KeyChord) {
        guard actionEnvironment.isAccessibilityTrusted() else {
            if isHUDEnabled {
                hudController.showError("Keystroke actions need Accessibility — grant it in the Library.")
            }
            return
        }

        let summary: String
        switch keyLatch.toggle(gesture: gesture, chord: chord) {
        case .engaged(let engaged):
            _ = actionEnvironment.postKeyDown(engaged)
            summary = "\(engaged.display) on"
        case .released(let released):
            _ = actionEnvironment.postKeyUp(released)
            summary = "\(released.display) off"
        case .swapped(let released, let engaged):
            _ = actionEnvironment.postKeyUp(released)
            _ = actionEnvironment.postKeyDown(engaged)
            summary = "\(engaged.display) on"
        }
        latchedChord = keyLatch.active?.chord
        if isHUDEnabled {
            hudController.show(gesture: gesture, actionSummary: summary, frame: latestFrame)
        }
    }

    /// The single chokepoint for every NON-toggle release of the latch. Posts the key-up
    /// synchronously if — and only if — a chord was actually latched; safe to call when nothing is.
    /// Silent by design (Ruling 4): the surface that caused it is the feedback.
    ///
    /// **Every place this is called, and why (the stuck-key audit for toggles):**
    ///  - `handleCaptureStateChange` — capture paused/interrupted/unavailable: master toggle off,
    ///    "Pause for an Hour", screen lock, display sleep, camera claimed elsewhere. No frames will
    ///    arrive to toggle it off, so it must end here.
    ///  - `handleApplicationWillTerminate` — app quit.
    ///  - the `mappingStore.$bindings` sink — the latched gesture was rebound, cleared, or disabled
    ///    in the Library (its binding is no longer `enabled` + `.toggleKeystroke(sameChord)`).
    ///  - `releaseLatch()` — the popover's "Release <key>" row.
    ///  - NOT on clutch disarm / command-window expiry (`apply(_:generation:timestamp:)`): the
    ///    latch exists precisely so the hand can rest while dictation continues (Ruling 2).
    private func releaseLatchIfNeeded() {
        guard let chord = keyLatch.release() else { return }
        latchedChord = nil
        _ = actionEnvironment.postKeyUp(chord)
    }

    /// Popover "Release <key>" row (Task 5). User-initiated, so it's the one forced release that
    /// does announce itself — using the latched gesture's own chip, like a second tap would.
    func releaseLatch() {
        guard let active = keyLatch.active else { return }
        releaseLatchIfNeeded()
        if isHUDEnabled {
            hudController.show(gesture: active.gesture, actionSummary: "\(active.chord.display) off", frame: latestFrame)
        }
    }
```

- [ ] **Step 3: Hold interplay (Ruling 3)** — in `handleHoldBegan(_:)`, right after the `case .holdKeystroke(let chord) = action` guard, add:

```swift
        // Ruling 3: a hold of a chord that's already latched is a no-op — the key is down, and
        // leaving `activeHoldChord` nil makes the matching `.ended` a no-op too, so the latch
        // (not the hold) still owns the eventual key-up.
        guard !keyLatch.isLatched(chord) else { return }
```

- [ ] **Step 4: Release inventory** — three call sites:
  1. `handleCaptureStateChange(_:)` (`:654`): inside the `if !isRunning(state) {` block, directly after the existing `endActiveHoldIfNeeded()` call, add `releaseLatchIfNeeded()` with a one-line comment `// Toggle latch: same chokepoint, same reasons (see releaseLatchIfNeeded()).`
  2. `handleApplicationWillTerminate()` (`:936`): make it release both. Replace the body with:

```swift
    private func handleApplicationWillTerminate() {
        releaseLatchIfNeeded()
        guard holdTracker.reset() != nil else { return }
        defer { hudController.endHold() }
        guard let chord = releaseActiveHold() else { return }
        _ = actionEnvironment.postKeyUp(chord)
    }
```

  3. The `mappingStore.$bindings` sink in `init` (`:331-339`): add, inside the closure after `recomputeAccessibilityWarning()`:

```swift
                // Toggle latch: the latched gesture's binding changed out from under it.
                if let active = self.keyLatch.active {
                    let binding = bindings[active.gesture]
                    let stillLatchBound = binding?.enabled == true && binding?.action == .toggleKeystroke(active.chord)
                    if !stillLatchBound {
                        self.releaseLatchIfNeeded()
                    }
                }
```

- [ ] **Step 5: Build + full suite**

Run: `./scripts/test.sh`
Expected: compiles with no new warnings under Swift 6 (the sink closure is already `@MainActor`-hopped by Combine on the main-actor class — if the compiler flags `keyLatch` access as non-isolated, wrap the block in `MainActor.assumeIsolated { … }` the same way the other sinks in this `init` access `self`'s isolated state), all tests green.

- [ ] **Step 6: Self-audit the inventory** — before reporting DONE, `grep -n "releaseLatchIfNeeded\|handleToggleFire\|keyLatch" Sources/Tacit/TacitEngine.swift` and confirm: 1 declaration, 1 toggle call in `handleFire`, 1 `isLatched` guard in `handleHoldBegan`, and `releaseLatchIfNeeded()` called from exactly `handleCaptureStateChange`, `handleApplicationWillTerminate`, the bindings sink, and `releaseLatch()`. Paste that grep output into your report.

- [ ] **Step 7: Commit + push**

```bash
git add Sources/Tacit/TacitEngine.swift
git commit -m "feat: engine-owned toggleKeystroke latch with full release-path inventory"
git push origin main
```

---

### Task 5: Library binder mode picker, popover "Release" row, README

**Files:**
- Modify: `Sources/Tacit/Library/ActionBinders.swift:134-165` (`ActionKind`), `:175-270` (`KeystrokeBinder`)
- Modify: `Sources/Tacit/PopoverView.swift:26-57` (row stack), add a `latchRow`
- Modify: `README.md:28-35`

**Interfaces:**
- Consumes: `TacitEngine.latchedChord`, `TacitEngine.releaseLatch()` (Task 4); `TacitAction.toggleKeystroke` (Task 1).

- [ ] **Step 1: `KeystrokeMode`** — add above `KeystrokeBinder` in `ActionBinders.swift`:

```swift
/// The three ways a recorded chord can be delivered — one segment each. `init(action:)` reads the
/// mode back out of an existing binding so re-opening a card shows the right segment selected.
private enum KeystrokeMode: CaseIterable, Identifiable, Hashable {
    case press, hold, toggle

    var id: Self { self }

    var label: String {
        switch self {
        case .press: "Press"
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }

    init(action: TacitAction?) {
        switch action {
        case .holdKeystroke: self = .hold
        case .toggleKeystroke: self = .toggle
        default: self = .press
        }
    }

    func action(for chord: KeyChord) -> TacitAction {
        switch self {
        case .press: .keystroke(chord)
        case .hold: .holdKeystroke(chord)
        case .toggle: .toggleKeystroke(chord)
        }
    }
}
```

- [ ] **Step 2: Replace the hold toggle in `KeystrokeBinder`:**
  - Replace `@State private var holdInsteadOfPress: Bool` and the `init` branches with `@State private var mode: KeystrokeMode` initialised via `_mode = State(initialValue: KeystrokeMode(action: store.binding(for: entry.id).action))`.
  - Replace the `Toggle("Hold instead of press", …)` view with:

```swift
            Picker("Delivery", selection: $mode) {
                ForEach(KeystrokeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: 44)
```

  - In `startRecording()`, replace `let action: TacitAction = holdInsteadOfPress ? .holdKeystroke(chord) : .keystroke(chord)` with `let action = mode.action(for: chord)`.
  - In `currentChord`, extend the pattern: `case .keystroke(let chord), .holdKeystroke(let chord), .toggleKeystroke(let chord):`.
  - Update the `KeystrokeBinder` doc comment: it now "carries the Press / Hold / Toggle delivery picker; this segment is the only place `.holdKeystroke` and `.toggleKeystroke` are bindable from the UI". Keep the "nothing written until a capture actually commits" sentence.
  - `ActionKind.init` (`:159`) already maps `.toggleKeystroke` to `.keystroke` (Task 1); update its doc comment (`:150-153`) to mention the picker instead of the toggle.

- [ ] **Step 3: Popover row** — in `PopoverView.swift`, after `pauseButton` in the `VStack` (`:28`), add `latchRow` and define it near `pauseButton`:

```swift
    /// Shown only while a `.toggleKeystroke` chord is latched down — the always-visible way out
    /// of a hands-free dictation latch (spec §6: never a silent held key). Plain verb, one accent
    /// use is NOT warranted here (this is a state row, not the armed state).
    @ViewBuilder
    private var latchRow: some View {
        if let chord = engine.latchedChord {
            Button {
                engine.releaseLatch()
            } label: {
                HStack {
                    Text("Holding \(chord.display)")
                    Spacer()
                    Text("Release")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
            .frame(minHeight: 44)
        }
    }
```

Add `engine.latchedChord` to the `.animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: …)` modifier chain at `:57` (a second `.animation(..., value: engine.latchedChord)` line, same token) so the row's appearance uses the standard transition.

- [ ] **Step 4: README** — replace the sentence in `README.md:29-32` ("among them three workflow defaults: a swipe switches apps, swipe-up focuses the nearest text field, and holding a point gesture holds down Fn, which is Wispr Flow's stock hotkey for push-to-talk dictation (rebindable …)") with:

> among them the workflow defaults, all on resting-hand poses: a victory sign switches apps (⌘Tab), a thumbs-up focuses the nearest text field, holding a point gesture holds down Fn — Wispr Flow's stock push-to-talk hotkey — and a thumb-to-ring/pinky tap *toggles* Fn for hands-free dictation until you tap again (the menu bar popover shows a "Release" row while it's held). Copy, paste, undo and redo ride the thumb taps and thumb swipes. Everything else ships off; every binding is rebindable in the Library, where a keystroke can be delivered as a press, a hold, or a toggle.

- [ ] **Step 5: Build the app and eyeball the two surfaces** — `./scripts/test.sh && ./scripts/make-app.sh && open build/Tacit.app`, then: open the Library → any keystroke-bound card → confirm the three-segment picker shows the right segment for the thumb–ring/pinky card ("Toggle"). Perform the clutch + thumb–ring/pinky tap → the popover shows "Holding Fn · Release"; click Release → row disappears. (Quit and relaunch is fine; no permission changes needed.) Write what you saw in your report; if you cannot grant camera access in your session, say so explicitly rather than claiming you saw it.

- [ ] **Step 6: Commit + push**

```bash
git add Sources/Tacit/Library/ActionBinders.swift Sources/Tacit/PopoverView.swift README.md
git commit -m "feat: keystroke delivery picker (press/hold/toggle) and popover latch release row"
git push origin main
```

---

### Task 6: Ship — rebuild, verify the live install migrated, handoff note

**Files:**
- Modify: `docs/NEXT-STEPS.md` (status section)
- No source changes.

- [ ] **Step 1: Rebuild and relaunch the real app**

```bash
cd ~/Developer/tacit && ./scripts/test.sh && ./scripts/make-app.sh
pkill -x Tacit || true
open build/Tacit.app
sleep 3
```

- [ ] **Step 2: Verify the user's real `mappings.json` migrated to rev 3** — run this read-only check and paste its output into your report:

```bash
python3 - <<'EOF'
import json, os
p = os.path.expanduser('~/Library/Application Support/Tacit/mappings.json')
d = json.load(open(p)); b = d['bindings']
def a(k): return json.dumps(b.get(k, {}).get('action')), b.get(k, {}).get('enabled')
for k in ['victory','thumbsUp','thumbRingPinkyTap','indexPoint','swipeRight','swipeUp','thumbIndexTap','thumbMiddleTap','thumbSwipeForward','thumbSwipeBackward']:
    print(f"{k:20s} enabled={a(k)[1]!s:5s} action={a(k)[0]}")
EOF
defaults read -g tacit.defaultsRevision 2>/dev/null; defaults find tacit.defaultsRevision | grep -v Tests | head -3
```

Expected: `victory` → `{"keystroke": {"_0": {"keyCode": 48, "modifiers": 1}}}` enabled; `thumbsUp` → `{"focusTextInput": {}}` enabled; `thumbRingPinkyTap` → `{"toggleKeystroke": {"_0": {"keyCode": 63, "modifiers": 0}}}` enabled; `swipeRight`/`swipeUp` enabled=False; revision key = 3 in the app's domain. If any line differs, report BLOCKED with the output — do not hand-edit the file.

- [ ] **Step 3: Update `docs/NEXT-STEPS.md`** — under "## Where the project is", add a paragraph:

> **Workhorse remap (2026-08-24, plan `docs/superpowers/plans/2026-08-24-tacit-workhorse-remap.md`): shipped.** Defaults revision 3 — victory→⌘Tab, thumbs-up→focus text input, thumb–ring/pinky tap→Toggle Fn (hands-free dictation, engine-owned `KeyLatch`), swipes off. `MappingStore` now carries a `DefaultsRevision` chain (`tacit.defaultsRevision`) instead of the M3 bool flag. Keystrokes have Press / Hold / Toggle delivery in the binder; the popover shows a "Release" row while a chord is latched.

And under "## Remaining steps", replace the list with: `1. Manual smoke test of the remap (2 min): clutch → victory switches apps; thumbs-up focuses a text field; thumb–ring/pinky tap starts Wispr Flow dictation hands-free, tap again stops it, popover "Release" also stops it. 2. Fixture recording session + ≥90% accuracy gate (user-gated; ⌥ in the popover reveals the recorder).`

- [ ] **Step 4: Commit + push**

```bash
git add docs/NEXT-STEPS.md
git commit -m "docs: workhorse remap shipped; next steps"
git push origin main
```

---

## Self-review (lead)

**Spec coverage.** §3.5 dispatcher: Task 1 adds the case + fallback, Task 3 amends the spec text. §3.6 defaults: Task 3 (values, chain, spec amendment). §4 UI rules: Task 5 reuses existing styles/tokens, 44pt, plain verbs, no new accent use. §6 trust: the latch is always visible in the popover (Task 5) and has a complete release inventory (Task 4); safety releases on every capture stop. User rulings (trio + copy/paste + undo/redo on workhorses, others off, Fn hold kept, second gesture toggles): all in the rev-3 table.

**Placeholder scan.** Every code step carries the code. The only "copy existing" instruction (Task 1 dispatch tests) names exact file:line ranges and the exact substitution.

**Type consistency.** `KeyLatch.toggle(gesture:chord:) -> LatchTransition`, `release() -> KeyChord?`, `isLatched(_:)`, `active: LatchedKey?` are used identically in Tasks 2 and 4. `TacitEngine.latchedChord` / `releaseLatch()` match between Tasks 4 and 5. `KeystrokeMode.action(for:)` is defined and used only in Task 5. `MappingStore.currentDefaultsRevision` / `defaultsRevisionKey` / `legacyWorkflowDefaultsAppliedKey` match between the Task 3 implementation and its tests (tests use string literals equal to the constants).

**Known gap, accepted:** `TacitEngine` has no unit tests (pre-existing — the app target has none); Task 4's correctness rests on the reviewer holding the diff to the inventory in Ruling 2 and on Task 5/6's manual check.
