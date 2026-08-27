import Foundation
import Testing
import TacitCore
@testable import Tacit

/// Stuck-key chokepoint tests (code review 2026-08-27, Finding 2 / item (d), task breakdown
/// items 2–5): every one of these funnels a real modifier key back UP after some interruption —
/// capture pausing, a screen lock, a rebind in the Library, or Accessibility being revoked. Each
/// test drives `TacitEngine` through the injected `ActionEnvironmentSpy` harness documented in
/// `Tests/TacitTests/README.md` and asserts the spy's ordered `keyLog` directly — no mock of
/// `TacitEngine` itself, no stubbing of the chokepoint methods under test.
@MainActor
struct ChokepointTests {

    /// Begins a hold the same way `apply(_:generation:timestamp:)` does (`TacitEngine.swift:1042`):
    /// feeds a matching `fired`/`candidate` pair into `engine.holdTracker.ingest(...)` — mutating
    /// `holdTracker`'s own bookkeeping, not just `TacitEngine.activeHoldChord` — and, only if that
    /// returns a transition, routes it through `handleHoldEvent(_:)`. `holdTracker` is `internal`
    /// (not `private`) specifically so a test can reach it this way (2026-08-27 coordinator
    /// follow-up to this file). Calling `handleHoldEvent(.began)` directly, without first driving
    /// `holdTracker.ingest`, sets `activeHoldChord` (a real key-down) but leaves `holdTracker`
    /// empty — a state the shipped app can never produce, since `apply(...)` is the only caller of
    /// `holdTracker.ingest` and always calls it immediately before `handleHoldEvent`. This helper
    /// reproduces the real pairing instead.
    ///
    /// `candidate` is built with `confidence: 1.0` — `ingest`'s `.began` branch only inspects
    /// `candidate?.gesture`, never `confidence` (see `HoldTracker.swift:80-92`), so any value here
    /// is equally valid; `1.0` just reads as "the pose is unambiguously classifying."
    ///
    /// Local to this file on purpose (per the coordinator's instruction not to share code across
    /// the three sibling test files, which write the equivalent helper independently in theirs).
    @discardableResult
    private func beginHold(
        on engine: TacitEngine, gesture: GestureID, at timestamp: TimeInterval
    ) -> GestureHoldEvent? {
        let fired = GestureEvent(gesture: gesture, timestamp: timestamp)
        let candidate = GestureCandidate(gesture: gesture, confidence: 1.0, timestamp: timestamp)
        guard let holdEvent = engine.holdTracker.ingest(fired: fired, candidate: candidate, at: timestamp) else {
            return nil
        }
        engine.handleHoldEvent(holdEvent)
        return holdEvent
    }

    // MARK: - 1. Hold began -> capture pause -> key-up fires

    /// Begins a hold on `.indexPoint` (a `holdableGestures` member) bound to `.holdKeystroke` via
    /// `beginHold(on:gesture:at:)` above — which drives `holdTracker.ingest(...)` AND
    /// `handleHoldEvent(_:)` together, exactly mirroring `apply(_:generation:timestamp:)`'s own
    /// sequence, so both `holdTracker`'s bookkeeping and `activeHoldChord` end up genuinely set,
    /// matching real production state (see that helper's doc comment for why this matters: an
    /// earlier version of this test called `handleHoldEvent(.began)` directly, which sets
    /// `activeHoldChord` without touching `holdTracker` — a state the shipped app cannot reach, and
    /// which made `endActiveHoldIfNeeded()` correctly no-op instead of releasing). Asserts the
    /// key-down posted, then drives `handleCaptureStateChange(_:)` to `.paused` (a non-`.running`
    /// state) and asserts the matching key-up posts. This is the `handleCaptureStateChange`
    /// chokepoint the review's task breakdown names explicitly: capture pausing for ANY reason
    /// (master toggle off, "Pause for an Hour", screen lock, display sleep, camera claimed
    /// elsewhere) funnels through this one state-change handler, which must force any active hold's
    /// key back up because no more frames will arrive to end it organically.
    @Test func holdBeganThenCapturePauseForcesKeyUp() {
        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 63, modifiers: []) // Fn, the shipped default for .indexPoint

        mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(chord)), for: .indexPoint)

        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        let holdEvent = beginHold(on: engine, gesture: .indexPoint, at: 0)
        #expect(holdEvent?.phase == .began, "expected beginHold to report .began; got \(String(describing: holdEvent))")
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord)],
            "expected only the hold's key-down after beginHold; got \(spy.keyLog)"
        )

        // Capture pausing for any reason (here: simulated directly) must force the held key back
        // up — this is the chokepoint under test.
        engine.handleCaptureStateChange(.paused(reason: "test: capture paused"))

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord),
            ],
            "expected the hold's key-down followed by a key-up once capture stopped running; got \(spy.keyLog)"
        )
    }

    // MARK: - 2. Hold began -> screen lock (endActiveHoldIfNeeded stand-in) -> key-up fires

    /// Stands in for "hold began -> screen lock -> key-up fires". The real
    /// `com.apple.screenIsLocked` distributed notification cannot be driven from this test: its
    /// handler, `handleScreenLockSignal()`, guards on `case .running = capture.state`, and
    /// `capture` is a real, un-injected `CaptureEngine` that never reaches `.running` without an
    /// actual camera session (see `Tests/TacitTests/README.md`, "What's still `private`", final
    /// paragraph — this is the documented, already-established limitation, not something
    /// discovered here). The functional chokepoint every screen-lock-driven hold release actually
    /// goes through is `endActiveHoldIfNeeded()` — `handleScreenLockSignal()` -> `pauseIfRunning`
    /// -> `capture.pause(...)` -> `capture.$state` publishes `.paused` -> `handleCaptureStateChange`
    /// -> `endActiveHoldIfNeeded()`. This test begins the hold the same production-accurate way as
    /// `holdBeganThenCapturePauseForcesKeyUp()` (via `beginHold(on:gesture:at:)`, so `holdTracker`'s
    /// own bookkeeping and `activeHoldChord` are both genuinely set — see that helper's doc comment)
    /// and then calls the shared chokepoint directly, standing in for the screen-lock signal
    /// specifically because the notification path is unreachable without a camera, not because the
    /// chokepoint itself differs between the two triggers (capture-pause and screen-lock are
    /// literally the same code path from `handleCaptureStateChange` onward).
    @Test func holdBeganThenScreenLockChokepointForcesKeyUp() {
        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 63, modifiers: [])

        mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(chord)), for: .indexPoint)

        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        let holdEvent = beginHold(on: engine, gesture: .indexPoint, at: 0)
        #expect(holdEvent?.phase == .began, "expected beginHold to report .began; got \(String(describing: holdEvent))")
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord)],
            "expected only the hold's key-down after beginHold; got \(spy.keyLog)"
        )

        // Stand-in for the screen-lock signal — see this test's doc comment above for why.
        engine.endActiveHoldIfNeeded()

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord),
            ],
            "expected the hold's key-down followed by a key-up once endActiveHoldIfNeeded() ran (screen-lock chokepoint stand-in); got \(spy.keyLog)"
        )
    }

    // MARK: - 3. Toggle engaged -> binding rebound in the Library -> key-up fires

    /// Engages a latch on a non-holdable gesture bound to `.toggleKeystroke`, then rebinds that
    /// same gesture through a real `MappingStore.setBinding(_:for:)` call (simulating the Library
    /// UI) and asserts the `mappingStore.$bindings` sink wired in `TacitEngine.init`
    /// (`TacitEngine.swift:487-504`) notices the latched gesture no longer matches its own binding
    /// and force-releases the latch, posting the key-up.
    @Test func toggleEngagedThenReboundInLibraryForcesKeyUp() async {
        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

        // `.thumbIndexTap` is not in `TacitEngine.holdableGestures`, so a `.toggleKeystroke` binding
        // on it reaches `handleFire(_:)`'s toggle branch directly (see README's dispatch table),
        // not the hold path.
        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(chord)), for: .thumbIndexTap)

        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord)],
            "expected the toggle's key-down after the first fire; got \(spy.keyLog)"
        )
        spy.clearLogs()

        // Simulate the Library rebinding this same gesture out from under the live latch — a real
        // `MappingStore.setBinding(_:for:)` call, not a synthetic notification.
        let newChord = KeyChord(keyCode: 9, modifiers: [.command]) // ⌘V
        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(newChord)), for: .thumbIndexTap)

        // `mappingStore.$bindings` is a Combine `@Published` publisher with no `.receive(on:)` in
        // `TacitEngine.init`'s sink, so in practice the sink runs SYNCHRONOUSLY, on the same thread,
        // inside `setBinding`'s `bindings[id] = binding` assignment above — confirmed empirically
        // while writing this test (the un-awaited assertion below passes with no wait). This poll
        // is kept anyway as a documented, BOUNDED (5s max) safety net per the README's guidance, in
        // case that synchronous-delivery behavior ever changes (e.g. a future `.receive(on:)` added
        // upstream) — never an unbounded wait, never a bare sleep with no assertion behind it.
        var observedUp = false
        for _ in 0..<500 {
            if spy.keyLog.contains(ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord)) {
                observedUp = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(observedUp, "expected the old chord's key-up after rebinding; got \(spy.keyLog)")
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord)],
            "expected exactly one key-up (the released latch), no re-engage on the new chord (the rebind sink only releases, it never engages); got \(spy.keyLog)"
        )
    }

    // MARK: - 4. Toggle engaged -> Accessibility revoked -> second toggle still releases

    /// Engages a latch while Accessibility is trusted, revokes trust via the spy's mutable
    /// `isAccessibilityTrusted` flag, then fires the SAME toggle gesture again and asserts the
    /// key-up still posts. Covers the post-review fix at `handleToggleFire`'s `.released` branch
    /// (`TacitEngine.swift:1265-1272`): the release direction must never be gated on Accessibility,
    /// or a chord latched while trusted could never be turned back off once trust is revoked.
    @Test func toggleEngagedThenAccessibilityRevokedSecondToggleStillReleases() {
        let spy = ActionEnvironmentSpy(isAccessibilityTrusted: true)
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(chord)), for: .thumbIndexTap)

        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord)],
            "expected the toggle's key-down while trusted; got \(spy.keyLog)"
        )

        spy.isAccessibilityTrusted = false

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 1))

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord),
            ],
            "expected the second toggle to still release the latch (key-up) even though Accessibility was revoked in between; got \(spy.keyLog)"
        )
    }
}
