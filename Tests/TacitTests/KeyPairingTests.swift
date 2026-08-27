import Foundation
import Testing
import TacitCore
@testable import Tacit

/// Invariant tests for `TacitEngine`'s key-down/key-up pairing state machine — code review
/// 2026-08-27, Finding 2 / item (d), invariants 1 and 6, plus Finding 5 / item (c)'s ordering
/// regression. See `Tests/TacitTests/README.md` for the harness contract these tests drive
/// against (`ActionEnvironmentSpy`, `handleFire(_:)`, `handleHoldEvent(_:)`,
/// `TacitTestSupport.isolatedMappingStore()`).
///
/// The other four invariants from the review's task breakdown (capture-pause chokepoint, screen
/// lock, rebind-while-toggled, Accessibility-revoked-release) are owned by two other agents
/// writing separate files against this same harness — not duplicated here.

// MARK: - Shared chords

private let spaceChord = KeyChord(keyCode: 49, modifiers: [.command])       // ⌘Space
private let cmdZChord = KeyChord(keyCode: 6, modifiers: [.command])         // ⌘Z
private let shiftCmdZChord = KeyChord(keyCode: 6, modifiers: [.command, .shift]) // ⇧⌘Z
private let fnChord = KeyChord(keyCode: 63, modifiers: [])                  // Fn
private let optionPChord = KeyChord(keyCode: 35, modifiers: [.option])      // ⌥P
private let waveChord = KeyChord(keyCode: 49, modifiers: [.control])        // ⌃Space

/// Renders `keyLog` for assertion failure messages — `KeyOperation`'s synthesized description
/// isn't very scannable, so failures print `"down ⌘Z, up ⌘Z, ..."` instead.
private func describe(_ log: [ActionEnvironmentSpy.KeyOperation]) -> String {
    log.map { "\($0.kind.rawValue) \($0.chord.display)" }.joined(separator: ", ")
}

// MARK: - 1. Key-down/key-up pairing across a mixed sequence

/// Drives a realistic mixed sequence through `handleFire`/`handleHoldEvent` — a `.keystroke` fire
/// (contributes only a `.press`, no down/up), a toggle engage, a toggle release from a SECOND
/// gesture bound to the same chord (mirrors `KeyLatchTests.sameChordFromADifferentGestureStillReleases`),
/// a toggle swap (one call posts an up then a down), a `.holdKeystroke` momentary fallback on a
/// non-holdable gesture (one call posts a down then an up), and a real hold begin/end pair on a
/// holdable gesture driven via `handleHoldEvent(_:)` — five distinct chords, five different code
/// paths that produce `.down`/`.up`, run in sequence. This is a property check over that whole
/// sequence, not one hand-picked case: every `.down` must have exactly one matching `.up` of the
/// SAME chord, and the same-chord open/close intervals must be well-formed (no chord going down
/// twice before its up, no up with nothing open for that chord).
@MainActor
@Test func keyDownsAndKeyUpsPairOneToOneAcrossAMixedSequence() {
    let spy = ActionEnvironmentSpy()
    let mappingStore = TacitTestSupport.isolatedMappingStore()
    let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

    // 0. `.keystroke` fire — one `.press`, must not disturb the down/up pairing check below.
    mappingStore.setBinding(GestureBinding(enabled: true, action: .keystroke(waveChord)), for: .wave)
    engine.handleFire(GestureEvent(gesture: .wave, timestamp: 0))

    // 1-2. Toggle engage, then release from a DIFFERENT gesture bound to the same chord.
    mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(spaceChord)), for: .thumbIndexTap)
    engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 1))
    mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(spaceChord)), for: .thumbMiddleTap)
    engine.handleFire(GestureEvent(gesture: .thumbMiddleTap, timestamp: 2))

    // 3-4. Toggle engage of one chord, then a SWAP (releases it, engages a second chord) from a
    // third gesture, then an explicit release of the swapped-in chord from a fourth gesture — kept
    // fully closed before moving on, so this sequence stays non-overlapping end to end.
    mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(cmdZChord)), for: .thumbRingPinkyTap)
    engine.handleFire(GestureEvent(gesture: .thumbRingPinkyTap, timestamp: 3))
    mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(shiftCmdZChord)), for: .palmTiltLeft)
    engine.handleFire(GestureEvent(gesture: .palmTiltLeft, timestamp: 4)) // swap: up cmdZ, down shiftCmdZ
    mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(shiftCmdZChord)), for: .swipeLeft)
    engine.handleFire(GestureEvent(gesture: .swipeLeft, timestamp: 5)) // release shiftCmdZ

    // 5. `.holdKeystroke` momentary fallback: `.palmTiltRight` is NOT in `holdableGestures`, so
    // this reaches `ActionDispatcher.dispatch`'s full-press fallback — down then up, one call.
    mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(fnChord)), for: .palmTiltRight)
    engine.handleFire(GestureEvent(gesture: .palmTiltRight, timestamp: 6))

    // 6. A genuine hold begin/end pair on a holdable gesture, driven directly via
    // `handleHoldEvent(_:)` (bypassing the untestable camera-driven `HoldTracker`).
    mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(optionPChord)), for: .indexPoint)
    engine.handleHoldEvent(GestureHoldEvent(gesture: .indexPoint, phase: .began, timestamp: 7))
    engine.handleHoldEvent(GestureHoldEvent(gesture: .indexPoint, phase: .ended, timestamp: 8))

    let log = spy.keyLog

    // Property 1: same-chord open/close intervals are well-formed — no orphan down, no double
    // up, no chord mismatch. Tracked independently of global ordering across DIFFERENT chords, so
    // this holds even if a future test nests one chord's open interval inside another's.
    var open = Set<String>() // keyed by `chord.display` (KeyChord isn't Hashable)
    for operation in log where operation.kind != .press {
        let key = operation.chord.display
        switch operation.kind {
        case .down:
            #expect(
                !open.contains(key),
                "double down for \(key) with no intervening up — full log: [\(describe(log))]"
            )
            open.insert(key)
        case .up:
            #expect(
                open.contains(key),
                "orphan up for \(key) with no matching open down — full log: [\(describe(log))]"
            )
            open.remove(key)
        case .press:
            break
        }
    }
    #expect(
        open.isEmpty,
        "chord(s) left down with no matching up: \(open.sorted()) — full log: [\(describe(log))]"
    )

    // Property 2: this sequence was deliberately kept non-overlapping (every chord fully closes
    // before the next one opens), so the flattened down/up chord lists must also match exactly,
    // in order — pairing AND ordering in one assertion, per the README's documented pattern.
    let downs = log.filter { $0.kind == .down }.map(\.chord)
    let ups = log.filter { $0.kind == .up }.map(\.chord)
    #expect(downs == ups, "downs \(downs.map(\.display)) != ups \(ups.map(\.display)) — full log: [\(describe(log))]")
    #expect(downs.count == 5, "expected 5 down/up pairs, got \(downs.count) — full log: [\(describe(log))]")

    // Sanity: the `.keystroke` fire contributed exactly one `.press` and nothing else.
    #expect(log.filter { $0.kind == .press } == [ActionEnvironmentSpy.KeyOperation(kind: .press, chord: waveChord)])
}

// MARK: - 2. `.holdKeystroke` on a holdable gesture never double-posts via `handleFire`

/// Finding 2's explicit hazard: a holdable gesture's `.holdKeystroke` is driven end to end by the
/// hold path (`handleHoldEvent` -> `handleHoldBegan`/`handleHoldEnded`); `handleFire` has its own
/// `.holdKeystroke` momentary-fallback branch that must NEVER also fire for a holdable gesture, or
/// the key posts twice. `.indexPoint` is in `TacitEngine.holdableGestures`. Reproduces the real
/// pipeline's per-frame shape (`apply(_:generation:timestamp:)` calls `handleFire` first, then
/// feeds `HoldTracker` -> `handleHoldEvent` on the SAME frame) and additionally stresses the
/// documented repeat-fire hazard: while a holdable pose stays held, a fired event re-arrives
/// roughly every ~0.9s (armed re-debounce + cooldown) — so `handleFire` is called again mid-hold,
/// and must still no-op every time.
@MainActor
@Test func holdKeystrokeOnHoldableGestureNeverDoublePostsViaHandleFire() {
    let spy = ActionEnvironmentSpy()
    let mappingStore = TacitTestSupport.isolatedMappingStore()
    mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(fnChord)), for: .indexPoint)

    let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

    // Frame 1: real pipeline order — `handleFire` runs before `HoldTracker` can even observe the
    // fire, so on the pose's onset frame `handleFire` sees the fire FIRST, before any hold exists.
    engine.handleFire(GestureEvent(gesture: .indexPoint, timestamp: 0))
    #expect(
        spy.keyLog.isEmpty,
        "handleFire posted before the hold began at all — full log: [\(describe(spy.keyLog))]"
    )

    // Same frame: the hold path takes over and posts the real key-down.
    engine.handleHoldEvent(GestureHoldEvent(gesture: .indexPoint, phase: .began, timestamp: 0))
    #expect(
        spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: fnChord)],
        "expected exactly one down after hold began — full log: [\(describe(spy.keyLog))]"
    )

    // Frames 2-4: the pose is still held. A fired event re-arrives on repeat frames while held
    // (the documented ~0.9s repeat-fire hazard) — simulate three such repeats. None may post.
    for repeatTimestamp in [1.0, 2.0, 3.0] {
        engine.handleFire(GestureEvent(gesture: .indexPoint, timestamp: repeatTimestamp))
    }
    #expect(
        spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: fnChord)],
        "a repeat handleFire mid-hold double-posted — full log: [\(describe(spy.keyLog))]"
    )

    // The pose is released: the hold path posts the matching key-up.
    engine.handleHoldEvent(GestureHoldEvent(gesture: .indexPoint, phase: .ended, timestamp: 4))

    #expect(
        spy.keyLog == [
            ActionEnvironmentSpy.KeyOperation(kind: .down, chord: fnChord),
            ActionEnvironmentSpy.KeyOperation(kind: .up, chord: fnChord),
        ],
        "expected exactly one down/up pair for the whole hold lifecycle — full log: [\(describe(spy.keyLog))]"
    )
}

// MARK: - 3. Ordering regression for item (c) / commit 9fc5f2c (Finding 5)

/// The ⌘Z / ⇧⌘Z bug: `thumbSwipeBackward` and `thumbSwipeForward` are separate gestures with
/// independent 0.8s per-gesture cooldowns (`ArbitrationEngine.swift:12,93`), so they can fire on
/// consecutive ~66ms frames. Before item (c), each `.keystroke` fire went through its own
/// `Task.detached` closure with no ordering guarantee relative to the other — the target app
/// could receive redo before undo. Item (c) made keystroke-shaped actions post synchronously on
/// the main actor instead, so `spy.keyLog` is guaranteed complete and in fire order the instant
/// `handleFire(_:)` returns — no `await`, no polling.
///
/// This test asserts the log immediately after each pair of `handleFire` calls, with no sleep or
/// poll of any kind. That absence is deliberate and load-bearing: if item (c) were reverted,
/// `.keystroke` would go back through two independent `Task.detached` closures, and `spy.keyLog`
/// would almost certainly still be empty (or incomplete/misordered) at the exact moment this
/// assertion runs, since a detached task cannot win a race against the very next synchronous line
/// of this test. Either way — wrong order, or simply not there yet — a revert fails this test.
@MainActor
@Test func consecutiveKeystrokeFiresReachSpyInFireOrder() {
    let spy = ActionEnvironmentSpy()
    let mappingStore = TacitTestSupport.isolatedMappingStore()
    mappingStore.setBinding(GestureBinding(enabled: true, action: .keystroke(cmdZChord)), for: .thumbSwipeBackward)
    mappingStore.setBinding(GestureBinding(enabled: true, action: .keystroke(shiftCmdZChord)), for: .thumbSwipeForward)

    let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

    // Undo (⌘Z) fires, then redo (⇧⌘Z) fires ~66ms later — the exact reported bug scenario.
    engine.handleFire(GestureEvent(gesture: .thumbSwipeBackward, timestamp: 0))
    engine.handleFire(GestureEvent(gesture: .thumbSwipeForward, timestamp: 0.066))

    #expect(
        spy.keyLog == [
            ActionEnvironmentSpy.KeyOperation(kind: .press, chord: cmdZChord),
            ActionEnvironmentSpy.KeyOperation(kind: .press, chord: shiftCmdZChord),
        ],
        "undo/redo arrived out of fire order — full log: [\(describe(spy.keyLog))]"
    )

    spy.clearLogs()

    // Reverse the fire order to prove the log tracks CALL order generically, not some incidental
    // fixed ordering between these two specific gestures/chords.
    engine.handleFire(GestureEvent(gesture: .thumbSwipeForward, timestamp: 1))
    engine.handleFire(GestureEvent(gesture: .thumbSwipeBackward, timestamp: 1.066))

    #expect(
        spy.keyLog == [
            ActionEnvironmentSpy.KeyOperation(kind: .press, chord: shiftCmdZChord),
            ActionEnvironmentSpy.KeyOperation(kind: .press, chord: cmdZChord),
        ],
        "reversed fire order was not preserved — full log: [\(describe(spy.keyLog))]"
    )
}
