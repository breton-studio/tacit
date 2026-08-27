import Foundation
import Testing
import TacitCore
@testable import Tacit

/// Process-lifecycle tests (code review 2026-08-27, Finding 2 / item (d) invariant 7, plus Finding
/// 3 / item (b)'s cold-start crash recovery): the paths that must not leave a modifier key stuck
/// down on the user's machine when Tacit goes away, whether cleanly (`handleApplicationWillTerminate`)
/// or not (a crash/SIGKILL, recovered on the NEXT launch via `TacitEngine.init`'s cold-start block).
/// Every test drives `TacitEngine` through the injected `ActionEnvironmentSpy` harness documented
/// in `Tests/TacitTests/README.md`.
///
/// ## `UserDefaults` isolation for the cold-start recovery group
///
/// `TacitEngine.init`'s recovery block, and `persistLatchedChord`/`clearPersistedLatchedChord`,
/// hardcode `UserDefaults.standard` (`TacitEngine.swift:408-413, 1197-1210`) — this is NOT
/// threaded through `MappingStore`'s injectable `UserDefaults`, nor through any init parameter,
/// so unlike `TacitTestSupport.isolatedMappingStore()` there is no suite-name seam available here.
/// This was verified empirically before writing these tests, not assumed:
///
/// - `./scripts/test.sh` launches via `swift test` (`scripts/test.sh`), whose host process is
///   `swiftpm-testing-helper`, not the shipped app's bundle ID `studio.breton.tacit` — confirmed by
///   inspecting `~/Library/Preferences/` on the machine these tests were written on: a
///   `swiftpm-testing-helper.plist` exists (already containing `tacit.firstFireCelebrated`, written
///   by another test's plain `TacitEngine()` construction reading/writing `UserDefaults.standard`
///   for its OTHER keys), and no `studio.breton.tacit.plist` exists at all. So `UserDefaults.standard`
///   inside this test binary is already, structurally, a different on-disk domain than the real
///   shipped app's — every engine construction in this whole test target (including the existing
///   `SmokeTests.swift`) already relies on exactly this fact for its `tacit.enabled`/`tacit.hudEnabled`/
///   etc. reads, so touching `tacit.latchedChord` under the same `UserDefaults.standard` is no new
///   exposure, and does NOT touch the real app's defaults.
/// - What IS this file's own responsibility: not leaking a seeded `tacit.latchedChord` value across
///   test boundaries WITHIN this shared domain, since `TacitEngine.init` (called by every other
///   test file too) unconditionally reads this exact key on every construction. Two measures:
///   1. Every test that writes this key removes it again before returning (`defer`), even on an
///      early `#expect` failure (Swift Testing's `#expect` records an issue and continues, it does
///      not unwind — `defer` is the only thing that reliably still runs).
///   2. Every test body below is fully synchronous (no `await`, no `Task`) and `@MainActor`, so the
///      whole seed → construct → assert → clean-up sequence runs as one atomic, non-suspending
///      unit of main-actor work — nothing else scheduled on the main actor (another file's
///      `TacitEngine` construction, also necessarily `@MainActor`) can interleave and observe the
///      key mid-test. See this file's test bodies: none contains `await`.
@MainActor
struct LifecycleTests {

    /// Duplicated from `TacitEngine`'s own `private static let latchedChordDefaultsKey` — `private`
    /// stays inaccessible even via `@testable import` (unlike `internal`), so the literal has to be
    /// repeated here. Keep it in sync with `TacitEngine.swift:230` if that string ever changes.
    private static let latchedChordDefaultsKey = "tacit.latchedChord"

    /// Removes any value under `latchedChordDefaultsKey`, so a test starts from — and, via each
    /// call site's `defer`, ends at — a clean slate in the shared `UserDefaults.standard` domain
    /// this whole test binary runs under. Safe to call when nothing is there.
    private static func clearPersistedLatchedChordDefault() {
        UserDefaults.standard.removeObject(forKey: latchedChordDefaultsKey)
    }

    /// Begins a hold the way the real per-frame pipeline actually does
    /// (`apply(_:generation:timestamp:)`, `TacitEngine.swift:1031-1033`): ingest a matching
    /// `fired`/`candidate` pair into `engine.holdTracker` and, only if that reports a `.began`
    /// transition, route the resulting event through `handleHoldEvent(_:)` — the same two-step
    /// `apply` performs on one frame. `holdTracker` is `internal` (post-review fix, was `private`
    /// — see this method's origin below), so `@testable import Tacit` can reach it directly.
    ///
    /// This is deliberately NOT just `engine.handleHoldEvent(GestureHoldEvent(gesture:phase:
    /// timestamp:))` called on its own: that call sets `activeHoldChord` and posts the key-down
    /// (via `handleHoldBegan`) but leaves `holdTracker`'s OWN internal `activeGesture` at `nil`,
    /// because `handleHoldEvent(_:)` itself never touches `holdTracker` — only `ingest`
    /// (called from `apply`) and `reset()` (called from `endActiveHoldIfNeeded()` and
    /// `handleApplicationWillTerminate()`) do. Earlier versions of this test drove the hold that
    /// way and both `handleApplicationWillTerminate` hold-release assertions failed as a result —
    /// `handleApplicationWillTerminate()`'s hold-release is gated on `holdTracker.reset() != nil`,
    /// which was never `true` for a hold set up by `handleHoldEvent` alone. That was a genuine
    /// test-seam gap, not a production bug (in the shipped app `activeHoldChord` and
    /// `holdTracker.activeGesture` are only ever set together, via this same ingest→handleHoldEvent
    /// pairing) — confirmed independently by `ChokepointTests.swift`'s two hold-release tests
    /// hitting the identical root cause. Fixed at the source by widening `holdTracker` to
    /// `internal`; this helper is what that widening was for — reproduce `apply`'s real two-step
    /// sequence instead of only its second half.
    ///
    /// Returns whether `ingest` actually reported `.began` (it always should for a fresh
    /// `holdableGestures` member with a matching candidate — see `HoldTracker.swift:80-105`) so a
    /// caller can assert on it rather than silently no-op if that ever stops being true.
    @discardableResult
    private static func beginHoldViaRealPipeline(
        _ engine: TacitEngine, gesture: GestureID, at timestamp: TimeInterval
    ) -> Bool {
        let fired = GestureEvent(gesture: gesture, timestamp: timestamp)
        let candidate = GestureCandidate(gesture: gesture, confidence: 1.0, timestamp: timestamp)
        guard let holdEvent = engine.holdTracker.ingest(fired: fired, candidate: candidate, at: timestamp) else {
            return false
        }
        engine.handleHoldEvent(holdEvent)
        return true
    }

    // MARK: - 1. `handleApplicationWillTerminate()` releases a live hold and/or a live latch

    /// A hold alone: `.indexPoint` (holdable) bound to `.holdKeystroke`, begun via
    /// `beginHoldViaRealPipeline(_:gesture:at:)` — which reproduces the real pipeline's
    /// ingest-then-`handleHoldEvent` sequence rather than calling `handleHoldEvent(.began)` in
    /// isolation, so `holdTracker`'s own bookkeeping is genuinely live, matching what an actual
    /// held pose leaves behind — then `handleApplicationWillTerminate()`. Expect the paired key-up.
    ///
    /// (Earlier revision of this test drove the hold via `handleHoldEvent(.began)` alone, which
    /// left `holdTracker.activeGesture` at `nil` even though `activeHoldChord` was genuinely set,
    /// and failed here as a result — see `beginHoldViaRealPipeline`'s doc comment for the full
    /// story of that gap and its fix: `holdTracker` widened from `private` to `internal`.)
    @Test func handleApplicationWillTerminateReleasesALiveHoldAlone() {
        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let holdChord = KeyChord(keyCode: 63, modifiers: []) // Fn, the shipped .indexPoint default

        mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(holdChord)), for: .indexPoint)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        let began = Self.beginHoldViaRealPipeline(engine, gesture: .indexPoint, at: 0)
        #expect(began, "expected holdTracker.ingest(...) to report a .began transition for .indexPoint")
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: holdChord)],
            "expected only the hold's key-down after beginning the hold; got \(spy.keyLog)"
        )

        engine.handleApplicationWillTerminate()

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: holdChord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: holdChord),
            ],
            "expected handleApplicationWillTerminate() to post the hold's key-up; got \(spy.keyLog)"
        )
    }

    /// A latch alone: a non-holdable gesture bound to `.toggleKeystroke`, engaged via `handleFire(_:)`,
    /// then `handleApplicationWillTerminate()` — expect the paired key-up. This path
    /// (`releaseLatchIfNeeded()`, called first thing inside `handleApplicationWillTerminate()`) does
    /// not depend on `holdTracker` at all, so — unlike the hold-alone test above — this one is
    /// expected to, and does, pass. Also asserts the Finding 3 crash-recovery record
    /// (`tacit.latchedChord`) is cleared by the same call, covering one of the four
    /// `clearPersistedLatchedChord()` call sites named in this suite's brief.
    @Test func handleApplicationWillTerminateReleasesALiveLatchAlone() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let latchChord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(latchChord)), for: .thumbIndexTap)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: latchChord)],
            "expected only the latch's key-down after the first fire; got \(spy.keyLog)"
        )
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) != nil,
            "expected the engage to persist tacit.latchedChord (Finding 3 crash recovery)"
        )

        engine.handleApplicationWillTerminate()

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: latchChord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: latchChord),
            ],
            "expected handleApplicationWillTerminate() to post the latch's key-up; got \(spy.keyLog)"
        )
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil,
            "expected handleApplicationWillTerminate() -> releaseLatchIfNeeded() to clear tacit.latchedChord"
        )
    }

    /// Both at once: a live hold AND a live latch on independent chords/gestures, then a single
    /// `handleApplicationWillTerminate()` call. The hold is begun via
    /// `beginHoldViaRealPipeline(_:gesture:at:)` (see that method's doc comment) so `holdTracker`'s
    /// bookkeeping is genuinely live, same as the hold-alone test above. Split into two
    /// `#expect`s (rather than one full-log equality) specifically so a run's output shows which
    /// half held and which didn't, instead of one opaque array diff.
    @Test func handleApplicationWillTerminateReleasesBothALiveHoldAndALiveLatch() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let holdChord = KeyChord(keyCode: 63, modifiers: []) // Fn, the shipped .indexPoint default
        let latchChord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

        mappingStore.setBinding(GestureBinding(enabled: true, action: .holdKeystroke(holdChord)), for: .indexPoint)
        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(latchChord)), for: .thumbIndexTap)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))
        let began = Self.beginHoldViaRealPipeline(engine, gesture: .indexPoint, at: 0)
        #expect(began, "expected holdTracker.ingest(...) to report a .began transition for .indexPoint")
        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: latchChord),
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: holdChord),
            ],
            "expected the latch's key-down then the hold's key-down before termination; got \(spy.keyLog)"
        )

        engine.handleApplicationWillTerminate()

        let ups = spy.keyLog.filter { $0.kind == .up }.map(\.chord)
        #expect(
            ups.contains(latchChord),
            "expected the live latch's key-up after handleApplicationWillTerminate(); got \(spy.keyLog)"
        )
        #expect(
            ups.contains(holdChord),
            "expected the live hold's key-up after handleApplicationWillTerminate(); got \(spy.keyLog)"
        )
    }

    // MARK: - 2. Cold-start crash recovery (Finding 3 / item (b), commit 3cb00f6)

    /// The headline behaviour: a chord left persisted in `tacit.latchedChord` by a previous process
    /// that never got to release it (SIGKILL/crash — `NSApplication.willTerminateNotification` does
    /// not fire for either) is replayed as a `postKeyUp` the NEXT time `TacitEngine.init` runs,
    /// unconditionally and before anything else, and the record is cleared so a second construction
    /// does not replay it again.
    @Test func coldStartRecoveryReplaysAndClearsAPersistedOrphanedChord() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let orphaned = KeyChord(keyCode: 63, modifiers: []) // Fn — the stuck-Fn scenario Finding 3 exists for
        let data = try! JSONEncoder().encode(orphaned)
        UserDefaults.standard.set(data, forKey: Self.latchedChordDefaultsKey)

        let firstSpy = ActionEnvironmentSpy()
        let firstMappingStore = TacitTestSupport.isolatedMappingStore()
        let firstEngine = TacitEngine(actionEnvironment: firstSpy.makeEnvironment(), mappingStore: firstMappingStore)
        _ = firstEngine // silence "never used" — the construction itself is what's under test

        #expect(
            firstSpy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .up, chord: orphaned)],
            "expected TacitEngine.init's cold-start recovery to post exactly one key-up for the orphaned chord, and nothing else; got \(firstSpy.keyLog)"
        )
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil,
            "expected cold-start recovery to clear tacit.latchedChord after replaying its key-up"
        )

        // The second half that matters: a SECOND construction, with the record now clear, must not
        // replay anything — a recovery that doesn't clear would re-post forever on every launch.
        let secondSpy = ActionEnvironmentSpy()
        let secondMappingStore = TacitTestSupport.isolatedMappingStore()
        let secondEngine = TacitEngine(actionEnvironment: secondSpy.makeEnvironment(), mappingStore: secondMappingStore)
        _ = secondEngine

        #expect(
            secondSpy.keyLog.isEmpty,
            "expected a second construction, after the first cleared tacit.latchedChord, to post nothing at cold start; got \(secondSpy.keyLog)"
        )
    }

    /// Engaging a `.toggleKeystroke` latch (a non-holdable gesture's first `handleFire(_:)`) writes
    /// the engaged chord to `tacit.latchedChord`, JSON-encoded — the write half of Finding 3's
    /// persist/clear pair, exercised independently of any release.
    @Test func engagingATogglePersistsTheLatchedChord() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 9, modifiers: [.command]) // ⌘V

        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(chord)), for: .thumbMiddleTap)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil,
            "expected nothing persisted yet, before any fire"
        )

        engine.handleFire(GestureEvent(gesture: .thumbMiddleTap, timestamp: 0))

        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord)],
            "expected the engage's key-down; got \(spy.keyLog)"
        )
        let persisted = UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey)
            .flatMap { try? JSONDecoder().decode(KeyChord.self, from: $0) }
        #expect(
            persisted == chord,
            "expected tacit.latchedChord to decode to the just-engaged chord \(chord); got \(String(describing: persisted))"
        )
    }

    /// The ordinary release: a second `handleFire(_:)` of the same toggle-bound gesture releases the
    /// latch (`handleToggleFire`'s `.released` branch) and must clear `tacit.latchedChord` — one of
    /// the four sites item (b) added `clearPersistedLatchedChord()` to. Also proves the clear
    /// actually sticks by constructing a fresh engine afterward and confirming cold-start recovery
    /// has nothing to replay.
    @Test func ordinaryToggleReleaseClearsTheLatchedChord() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let spy = ActionEnvironmentSpy()
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(chord)), for: .thumbIndexTap)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0)) // engage
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) != nil,
            "expected the engage to persist tacit.latchedChord before testing its release"
        )

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 1)) // release (second tap)

        #expect(
            spy.keyLog == [
                ActionEnvironmentSpy.KeyOperation(kind: .down, chord: chord),
                ActionEnvironmentSpy.KeyOperation(kind: .up, chord: chord),
            ],
            "expected engage then release; got \(spy.keyLog)"
        )
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil,
            "expected the ordinary second-tap release to clear tacit.latchedChord"
        )

        // Confirm the clear actually sticks for the next launch: a fresh engine's cold-start
        // recovery should find nothing and post nothing.
        let recoverySpy = ActionEnvironmentSpy()
        let recoveryMappingStore = TacitTestSupport.isolatedMappingStore()
        let recoveryEngine = TacitEngine(actionEnvironment: recoverySpy.makeEnvironment(), mappingStore: recoveryMappingStore)
        _ = recoveryEngine

        #expect(
            recoverySpy.keyLog.isEmpty,
            "expected no cold-start replay after an ordinary release cleared the record; got \(recoverySpy.keyLog)"
        )
    }

    /// One of the two untrusted-undo branches (`handleToggleFire`'s `.engaged` case, `trusted ==
    /// false`): the latch is engaged-then-immediately-undone with no key ever posted, but
    /// `clearPersistedLatchedChord()` still runs defensively. Seeds a stale persisted chord first
    /// (simulating a leftover record from an earlier, trusted engage) to make that defensive clear
    /// observable — with nothing seeded there is nothing to prove was cleared.
    @Test func untrustedEngageUndoClearsAnyStalePersistedChord() {
        Self.clearPersistedLatchedChordDefault()
        defer { Self.clearPersistedLatchedChordDefault() }

        let stale = KeyChord(keyCode: 1, modifiers: [.command, .shift])
        UserDefaults.standard.set(try! JSONEncoder().encode(stale), forKey: Self.latchedChordDefaultsKey)

        let spy = ActionEnvironmentSpy(isAccessibilityTrusted: false)
        let mappingStore = TacitTestSupport.isolatedMappingStore()
        let chord = KeyChord(keyCode: 8, modifiers: [.command])

        mappingStore.setBinding(GestureBinding(enabled: true, action: .toggleKeystroke(chord)), for: .thumbIndexTap)
        let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)

        // Cold-start recovery for the SEEDED stale chord already ran during `TacitEngine(...)` above
        // (it's unconditional, independent of Accessibility trust) — clear that expectation before
        // testing the untrusted-engage path specifically, so this test's own assertions are about
        // ONLY the engage attempt below, not the constructor's own recovery replay.
        #expect(
            spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .up, chord: stale)],
            "expected the seeded stale chord to be replayed-and-cleared by cold-start recovery during construction, same as coldStartRecoveryReplaysAndClearsAPersistedOrphanedChord(); got \(spy.keyLog)"
        )
        #expect(UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil)
        spy.clearLogs()

        // Re-seed, this time simulating a record left behind by something OTHER than this engine's
        // own cold start (e.g. a hand-edited default, or a race with another process) — the point
        // is only to prove `.engaged`'s untrusted-undo branch clears whatever is there, independent
        // of how it got there.
        UserDefaults.standard.set(try! JSONEncoder().encode(stale), forKey: Self.latchedChordDefaultsKey)

        engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))

        #expect(
            spy.keyLog.isEmpty,
            "expected no postKeyDown/postKeyUp at all — the untrusted engage is undone before any real key event is posted; got \(spy.keyLog)"
        )
        #expect(
            UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey) == nil,
            "expected the untrusted-engage-undo branch to clear tacit.latchedChord defensively"
        )
    }
}
