# Tacit code review — 2026-08-27

Reviewed at commit `ffe50da`, branch `main`, working tree clean.
Scope: `Sources/TacitCore`, `Sources/Tacit`, `Tests/`, `Package.swift`, `scripts/`, `README.md`.
Baseline: `./scripts/test.sh` → 303 tests, 3 suites, all green in 0.6s.

Five findings, most severe first. Each carries the evidence that established it and a task
breakdown sized to be executed without re-deriving anything.

Product item (f) from the original review — reopening the clutch-off default / adding an
`openPalm` panic-disarm — is **explicitly out of scope** for this pass. Finding 1's measurement
is the input to that decision, not a substitute for it.

---

## Finding 1 — The false-positive safety suite tests a configuration the app doesn't ship

**Severity: critical. The headline anti-Midas-touch evidence does not cover the shipped default.**

`NegativeSuiteTests` is the suite that proves synthetic typing and conversation streams never
fire a gesture. Every one of its engines is built with default tuning:

- `Tests/TacitCoreTests/NegativeSuiteTests.swift:403, 412, 436, 471, 486` — `ArbitrationEngine()`
- Default tuning has `requiresClutch = true` (`Sources/TacitCore/ArbitrationEngine.swift:43`)
- Every assertion is `#expect(!result.everArmed, ...)` — lines `406, 415, 474, 489`

The app ships the opposite:

- `Sources/Tacit/TacitEngine.swift:357` — `self.requiresClutch = storedRequiresClutch ?? false`

In clutch-off mode `ArbitrationEngine.init` sets `state = .armed(windowEndsAt: .infinity)`
immediately (`ArbitrationEngine.swift:136`). `everArmed` is therefore `true` by construction, so
those assertions are not merely unproven against the shipped mode — they are structurally
inapplicable to it.

**It is worse than "the wrong mode."** The two recorded-hand legs —
`recordedTypingNegativeFixturesNeverFireOrArmWhileDisarmed` and its conversation twin
(`NegativeSuiteTests.swift:463, 478`) — early-return with a `print` when no fixture is found.
`Tests/Fixtures/` does not exist in the repo (only `Tests/TacitCoreTests/` does), so **both legs
pass vacuously and always have.** `docs/NEXT-STEPS.md:26` already flags the related gap: the
≥90% real-hand accuracy gate has never been run.

Net: every piece of false-positive evidence Tacit has is (1) synthetic and (2) clutch-on. There
is no recorded-hand negative evidence at all, in either mode.

Clutch-off coverage today is 8 state-machine unit tests
(`Tests/TacitCoreTests/ArbitrationEngineTests.swift:565-680`). None of them feed noise.

What remains as the intent gate in shipped configuration:

- `clutchOffConfidenceBoost = 0.15` (`ArbitrationEngine.swift:51`)
- `debounceFrames = 3` (`ArbitrationEngine.swift:26`)

And nothing else. `processClutchOff` ignores reserved gestures
(`ArbitrationEngine.swift:388`), so `openPalm` no longer disarms — there is no in-gesture way to
stop a misfiring session, only the menu bar. Meanwhile ⌘Z / ⇧⌘Z ship enabled on the thumb swipes.

### Task breakdown — (a)

**Decision on record: land red. Failures are the deliverable, not a blocker.**

1. In `NegativeSuiteTests.swift`, parameterise `replayThroughFullChain` (line 90) over an
   `ArbitrationTuning` argument rather than hardcoding `ArbitrationEngine()`. Default it to the
   existing tuning so the current clutch-on legs are untouched.
2. Add clutch-off legs mirroring the four existing assertion tests
   (`syntheticTypingStreamNeverFiresOrArmsWhileDisarmed`,
   `syntheticConversationStream...`, `recordedTypingNegativeFixtures...`,
   `recordedConversationNegativeFixtures...`). Assert **only** `result.events.isEmpty` — drop
   `everArmed` entirely for these legs; it is meaningless when the engine is armed from
   construction.
3. Run across the same 11-seed sweep (`NegativeSuiteTests.swift:378`).
4. **Record the actual event counts in this document and in `EXECUTION-LOG.md`** — per gesture,
   per stream, per seed. That table is the real output of this task.
5. Do **not** tune `clutchOffConfidenceBoost` / `debounceFrames` to make it pass. Tuning against
   the synthetic generator would fit the noise model, not real hands. If the suite is red, it
   stays red and annotated until (f) is decided separately.
6. Make the vacuous recorded legs honest. Either fail loudly when `Tests/Fixtures/` is absent, or
   keep the skip but surface it — a `print` inside a passing test is invisible in a green run.
   The real fix is recording fixtures (⌥ in the popover reveals the recorder;
   `docs/NEXT-STEPS.md:20, 26`), which is user-gated and outside this pass.

**Acceptance:** clutch-off legs exist, run in `./scripts/test.sh`, and their result — pass or
fail with counts — is written down. The recorded legs no longer report green while doing nothing.

---

## Finding 2 — The app target has zero test coverage

**Severity: critical. Every line that actually posts a key event is untested.**

`Package.swift:20` declares exactly one test target: `TacitCoreTests`. All 303 tests are
`TacitCore`.

`Sources/Tacit/TacitEngine.swift` is 1,800 lines / 114KB and owns the complete key-down →
key-up pairing state machine:

- `handleHoldBegan` / `handleHoldEnded` (lines 1045, 1106)
- `handleToggleFire`, including the Accessibility-revoked release path (line 1134)
- `releaseLatchIfNeeded` / `releaseActiveHold` / `endActiveHoldIfNeeded` (lines 1225, 1254, 1279)
- `handleApplicationWillTerminate` (line 1293)
- The capture-pause / screen-lock / display-sleep chokepoints (lines 794, 732-792)
- The hold-vs-latch mutual-exclusion invariants (lines 1075, 1142)

`HoldTracker` and `KeyLatch` *are* tested — but by design they "never touch the keyboard"
(`Sources/TacitCore/KeyLatch.swift:14`). They are pure deciders. Every path that converts a
decision into a `CGEvent`, and every reconciliation between the hold path and the latch path,
is untested. That is exactly where a stuck key comes from.

### Task breakdown — (d)

The seam already exists: `ActionEnvironment` is a struct of injected `@Sendable` closures
(`Sources/TacitCore/ActionDispatcher.swift:6`) and is already spied in
`Tests/TacitCoreTests/ActionDispatcherTests.swift`. The blocker is that `TacitEngine`
hardcodes `LiveActionEnvironment.make()` at `TacitEngine.swift:175`.

1. Add `.testTarget(name: "TacitTests", dependencies: ["Tacit", "TacitCore"])` to
   `Package.swift`. Note `Tacit` is an `executableTarget` — confirm SwiftPM lets a test target
   depend on it on this toolchain; if not, extract the engine into a third library target rather
   than fighting it.
2. Inject `ActionEnvironment` through `TacitEngine.init` (currently
   `init(recorder: FixtureRecorder = FixtureRecorder())`), defaulting to
   `LiveActionEnvironment.make()` so production is unchanged.
3. Write a spy environment recording an ordered log of `(down/up/press, KeyChord)`.
4. Cover, at minimum, the invariants the doc comments already claim:
   - every `postKeyDown` is followed by exactly one `postKeyUp` of the same chord
   - hold began → capture pause → key-up fires (the `handleCaptureStateChange` chokepoint)
   - hold began → screen lock → key-up fires
   - toggle engaged → binding rebound in the Library → key-up fires (the `$bindings` sink,
     `TacitEngine.swift:427-432`)
   - toggle engaged → Accessibility revoked → second toggle still releases
     (the post-review fix at `TacitEngine.swift:1159-1165`)
   - a `.holdKeystroke` on a holdable gesture never double-posts via `handleFire`
     (`TacitEngine.swift:1374`)
   - `handleApplicationWillTerminate` releases both a live hold and a live latch

**Acceptance:** `./scripts/test.sh` runs both targets; the seven invariants above are asserted.

---

## Finding 3 — A stuck modifier key survives the process, with no recovery path

**Severity: high. Affects two enabled factory defaults.**

`README.md:97` documents it honestly: crash or force-quit with a hold/toggle key down leaves the
key stuck. The only release-on-exit hook is `NSApplication.willTerminateNotification`
(`TacitEngine.swift:711`, handled at `:1293`), which does not fire on SIGKILL or a crash.

Why this is not theoretical:

- `bindings[.indexPoint] = .holdKeystroke(Fn)` — enabled default (`MappingStore.swift:450`)
- `bindings[.victory] = .toggleKeystroke(Fn)` — enabled default (`MappingStore.swift:459`)
- The latch is *deliberately* designed to persist across clutch disarm and hand-rest
  (`TacitEngine.swift:1200-1201`, Ruling 2) — that is the feature, not a bug

The latched chord is never persisted. Confirmed against every `UserDefaults` key the engine
writes (`TacitEngine.swift:189-198`): `tacit.enabled`, `tacit.hudEnabled`,
`tacit.debugViewEnabled`, `tacit.sensitivity`, `tacit.cameraID`, `tacit.requiresClutch`,
`tacit.firstFireCelebrated` — plus `tacit.launchAtLoginConfigured`, `tacit.onboarded`,
`tacit.defaultsRevision` elsewhere. No latched-chord key exists, so relaunching Tacit cannot
clean up after a previous crash.

### Task breakdown — (b)

1. Add `tacit.latchedChord` — the `KeyChord` (already `Codable`,
   `Sources/TacitCore/KeyChord.swift:6`) JSON-encoded into `UserDefaults`.
2. Write it in `handleToggleFire` on `.engaged` / `.swapped`-engage, immediately after the
   successful `postKeyDown` (`TacitEngine.swift:1156, 1178`). Clear it everywhere `latchedChord`
   is set back to nil — `releaseLatchIfNeeded` (`:1227`) and both untrusted-undo branches
   (`:1150, 1172`).
3. In `TacitEngine.init`, before anything else: if a chord is persisted, post a `postKeyUp` for
   it and clear the key. This is a cold-start recovery, so it runs regardless of Accessibility
   state — a failed post is harmless, matching the existing unconditional-release convention.
4. Consider the same for `.holdKeystroke` (`activeHoldChord`, `TacitEngine.swift:317`). Lower
   priority: a hold's window is seconds, a latch's is unbounded.
5. Update `README.md:97` — the "tap the physical key" advice stays as the manual fallback, but
   note that a relaunch now clears it.

**Acceptance:** kill -9 the app with Fn latched, relaunch, Fn is released. Covered by a unit test
under (d) once the environment is injectable.

---

## Finding 4 — Blocking system calls run on the Swift cooperative thread pool

**Severity: high. Silent, unrecoverable recognition stall.**

`handleFire` dispatches actions via `Task.detached` (`TacitEngine.swift:1393`). The surrounding
doc comment (`:1381-1388`) justifies this as "never on the main actor" — true, but the wrong
invariant. `Task.detached` runs on the global cooperative pool (width ≈ `activeProcessorCount`),
not a private thread. Three blocking things run there:

| Call | Site | Blocking behaviour | Default bindings affected |
|---|---|---|---|
| `runShortcut` | `LiveActionEnvironment.swift:106` | `Process.waitUntilExit()`, no timeout, no `terminate()` — unbounded | none by default, but user-bindable |
| `focusTextInput` | `LiveActionEnvironment.swift:114` → `:162` | up to 400 synchronous cross-process `AXUIElementCopyAttributeValue` calls; no `AXUIElementSetMessagingTimeout`, AX default is 6s **per call** | `thumbsUp` |
| `switchApp` | `LiveActionEnvironment.swift:126` | `DispatchQueue.main.sync` — textbook priority inversion | `thumbIndexTap`, `thumbMiddleTap`, `palmTiltLeft`, `palmTiltRight` |

Starve the pool and `PipelineCore`'s actor executor cannot be scheduled. Recognition stalls
app-wide, with no visible failure state and no recovery short of quitting.

### Task breakdown — (e)

This is the largest item and the only one that changes a public signature. Sequence it last.

1. Make `ActionDispatcher.dispatch(_:)` `async`
   (`Sources/TacitCore/ActionDispatcher.swift:73`) and the three offending `ActionEnvironment`
   closures `async` (`:17-29`). `postKeystroke`/`postKeyDown`/`postKeyUp` stay synchronous — they
   are genuinely non-blocking `CGEvent` posts, and finding 5 depends on that.
2. `runShortcut`: keep `Process`, but replace `waitUntilExit()` with
   `terminationHandler` + a `withCheckedContinuation`, and add a timeout (10s is a defensible
   default for a Shortcut) that calls `terminate()` and returns `false`.
3. `focusTextInput`: call `AXUIElementSetMessagingTimeout(appElement, 0.5)` on the application
   element in `focusFrontmostTextInput` (`LiveActionEnvironment.swift:163`) before the walk. The
   400-node / depth-8 caps already exist; this bounds the per-call cost they assume.
4. `switchApp`: drop `DispatchQueue.main.sync` + `MainActor.assumeIsolated` in favour of a plain
   `await MainActor.run { AppSwitcher.shared.flip(direction) }`, now that the closure can be
   `async`. Deletes the whole rationale block at `:115-124`.
5. Update `handleFire`'s call site (`TacitEngine.swift:1394`) and the affected
   `ActionDispatcherTests` spies.

**Acceptance:** no `waitUntilExit`, no `DispatchQueue.main.sync`, and an AX messaging timeout is
set. Existing `ActionDispatcherTests` pass against the async signature.

---

## Finding 5 — `.keystroke` dispatch races itself via unordered `Task.detached`

**Severity: medium-high. User-visible wrong-order keystrokes; the codebase already states the rule
it breaks here.**

`TacitEngine.swift:1036-1044` states the rule explicitly — two independent `Task.detached`
closures have no ordering guarantee relative to each other, so key posting was moved to
synchronous main-actor calls for holds and toggles. The plain `.keystroke` path at
`TacitEngine.swift:1393` was left on `Task.detached`.

`thumbSwipeBackward` (⌘Z) and `thumbSwipeForward` (⇧⌘Z) are both enabled defaults
(`MappingStore.swift:435-440`) and are **separate gestures**, so their 0.8s per-gesture cooldowns
(`ArbitrationEngine.swift:12`, ledger keyed by gesture at `:93`) are independent. They can fire on
consecutive ~66ms frames. Two detached tasks, no ordering → the target app can receive redo before
undo.

The justification for detaching does not hold for this case either: the same comment block calls
`CGEvent(...).post` "microseconds-scale, non-blocking" (`TacitEngine.swift:1033-1035`). Only
`.runShortcut` / `.focusTextInput` / `.switchApp` need to be off the main actor.

### Task breakdown — (c)

1. In `handleFire`, split the dispatch by action kind. For `.keystroke` — and `.holdKeystroke` /
   `.toggleKeystroke` reaching the momentary fallback — call `actionEnvironment.postKeystroke`
   (or the down/up pair) **synchronously on the main actor**, exactly as `handleHoldBegan`
   already does at `TacitEngine.swift:1085`.
2. Keep `Task.detached` only for `.launchApp`, `.openURL`, `.runShortcut`, `.focusTextInput`,
   `.switchApp`.
3. `applyDispatchOutcome` (`:1410`) still runs for both paths — the synchronous path can call it
   directly rather than via `MainActor.run`, preserving the first-fire celebration bookkeeping.
4. Update the doc comment at `:1381-1388` so it states the real invariant: *ordering* is why
   keystrokes stay on the main actor, *blocking* is why the rest leave it.

**Acceptance:** two keystroke fires on consecutive frames are delivered in fire order. Assert via
the spy environment's ordered log under (d).

---

## Verified and cleared — do not re-derive

- **Secrets.** `.secrets/` is gitignored (`.gitignore:26`) and has never been committed —
  `git log --all -- .secrets` is empty. `.gstack/` and `.superpowers/` likewise ignored.
- **Supply chain.** Zero direct and transitive dependencies (`Package.swift`). No network client
  anywhere in the app. Consistent with `.gstack/security-reports/2026-08-27-160400.json`
  (0 findings).
- **Build.** `./scripts/make-app.sh` is intact; `Sources/Tacit/Resources/` contains `Info.plist`,
  `AppIcon.icns`, and 50 preview assets (25 `.mov` + 25 `.png`), all tracked.
- **Info.plist.** `NSCameraUsageDescription` present, `LSUIElement` set, bundle ID
  `studio.breton.tacit` matches the logging subsystem.
- **`MappingStore` migration.** The v1→v2 path and the revision-8 top-up chain are sound; the
  corrupt-file quarantine reports `fileExisted: false` correctly.
- **`README.md`** is accurate as of `ffe50da`, with one exception noted under (b) step 5.

## Known non-findings, deliberately not raised

- `postKeystroke` omits the `.maskSecondaryFn` special case that `postKeyDown`/`postKeyUp` apply
  for keyCode 63 (`LiveActionEnvironment.swift:64` vs `:25`). Latent, but unreachable: the
  Library's key recorder reads `NSEvent.keyCode` from a `keyDown`
  (`Sources/Tacit/Library/ActionBinders.swift:312`), and the physical Fn key emits
  `flagsChanged`, not `keyDown` — so `.keystroke(Fn)` cannot be bound through the UI.
- `TacitEngine.swift` is majority prose (114KB / 1,800 lines). A real maintainability concern and
  a god object, but not a defect; deferred deliberately.
