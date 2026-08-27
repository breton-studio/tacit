# Tacit code-review remediation — execution log
Updated: 2026-08-27 · Branch: main · Status: in progress ((b), (a), (c) done; (d), (e) remain)

## Goal
Close findings 1–5 from [`docs/CODE-REVIEW-2026-08-27.md`](docs/CODE-REVIEW-2026-08-27.md),
executed as items (a)–(e). Done means: the clutch-off false-positive behaviour is **measured**,
a latched key can no longer survive a crash, keystrokes are delivered in fire order, blocking
calls are off the cooperative thread pool, and the app target has tests covering the key
down/up pairing invariants.

Item (f) — reopening the clutch-off default / an `openPalm` panic-disarm — is **out of scope**
this pass. Finding 1's measurement feeds that decision later; it does not replace it.

## Done
- Full review at `ffe50da`. Findings + per-item task breakdowns written to
  `docs/CODE-REVIEW-2026-08-27.md`. Read that file first — it has the evidence and the
  file:line references; this log only tracks state.
- **(b) Persist the latched chord** — landed at `3cb00f6`.
- **(a) Clutch-off negative suite** — measured at `3cb00f6`. See "(a) RESULT" below.
- **(c) Move `.keystroke` dispatch to the main actor** — landed (working tree, not yet committed).
  `handleFire` (`TacitEngine.swift`, split point ~:1452) now switches on `action` kind:
  `.keystroke`/`.holdKeystroke`/`.toggleKeystroke` call `actionDispatcher.dispatch(action)`
  synchronously on the main actor and call `applyDispatchOutcome` directly; `.launchApp`/
  `.openURL`/`.runShortcut`/`.focusTextInput`/`.switchApp` stay on `Task.detached` exactly as
  before, hopping back via `MainActor.run`. Updated the two doc comments that asserted "never on
  the main actor" (the `actionDispatcher` property comment and `handleFire`'s dispatch-site
  comment) to state the real invariant: ordering forces the keystroke branch onto the main actor,
  blocking is what keeps the other five detached. `./scripts/test.sh` still 307 tests / 3 suites /
  exit 0 / 22 known issues (unchanged) — see review §Finding 5.

## In flight
- Nothing uncommitted beyond (c)'s working-tree change to `Sources/Tacit/TacitEngine.swift`.

## Next
1. **(d) `TacitTests` target** — inject `ActionEnvironment` through `TacitEngine.init`, spy the
   ordered key log, assert the seven invariants listed in the review. Also gives (b) and (c)
   their regression tests. See review §Finding 2.
2. **(e) Unblock the cooperative pool** — `dispatch(_:)` goes `async`; Process timeout, AX
   messaging timeout, drop `DispatchQueue.main.sync`. Largest, and the only public signature
   change — do it last. See review §Finding 4.


## (a) RESULT — clutch-off false-positive measurement

**Measured 2026-08-27 at `3cb00f6`. No thresholds were tuned; `Sources/TacitCore/` has zero
diff. The clutch-off tuning changes `requiresClutch` and nothing else.**

`./scripts/test.sh` → **307 tests, 3 suites, exit 0, with 22 known issues.** All 22 synthetic
clutch-off legs fire. Zero unexpected passes.

| Stream | Seeds firing | Min | Max | Mean | Total |
|---|---|---|---|---|---|
| typing (900 frames / 60 s) | **11 / 11** | 95 | 118 | 104.5 | 1,150 |
| conversation (450 frames / 30 s) | **11 / 11** | 5 | 11 | 7.9 | 87 |

**≈ 1 spurious gesture every 0.57 s of simulated typing.** Across the typing sweep
`thumbSwipeBackward` fired **39** times and `thumbSwipeForward` **27** — those are ⌘Z and ⇧⌘Z,
both enabled factory defaults. Roughly **3.5 spurious undos per minute of typing.**

**Why the boost does not save it:** `clutchOffConfidenceBoost` (+0.15) only raises the *static
classifier* gate (`effectiveEnterConfidence` / `effectiveStayConfidence`). The gestures actually
firing are overwhelmingly *momentary* detectors — `thumbIndexTap` (420), `thumbMiddleTap` (292),
wrist rotate (235), `thumbRingPinkyTap` (96) — and nothing raises the bar for those in clutch-off
mode. The clutch was doing all the work; removing it removes the brake entirely.

Corroborated by the suite's pre-existing informational leg: once armed *by any means*, the same
typing stream produces ~106 events. Clutch-off ≈ armed. The boost is close to a no-op here.

### Per-seed counts

| Seed | Stream | Events | Gesture breakdown |
|---|---|---:|---|
| `0x7e1711161dea1001` | conversation | 5 | thumbIndexTap:2, thumbSwipeForward:1, wristRotateCW:2 |
| `0x1` | conversation | 6 | fistToOpen:2, indexPoint:2, wristRotateCW:2 |
| `0xdeadbeefcafef00d` | conversation | 11 | thumbIndexTap:5, thumbMiddleTap:1, thumbSwipeBackward:2, thumbsUp:1, wristRotateCCW:1, wristRotateCW:1 |
| `0x123456789abcdef0` | conversation | 11 | fistToOpen:1, indexPoint:1, thumbIndexTap:5, thumbSwipeBackward:1, thumbsUp:1, wristRotateCCW:2 |
| `0xffffffffffffffff` | conversation | 7 | indexPoint:1, thumbIndexTap:3, thumbMiddleTap:1, thumbsUp:1, victory:1 |
| `0xbadf00d600dc0de` | conversation | 7 | thumbIndexTap:4, thumbMiddleTap:1, thumbsUp:1, wristRotateCW:1 |
| `0x9e3779b97f4a7c15` | conversation | 8 | indexPoint:1, thumbIndexTap:4, wristRotateCW:3 |
| `0x5eed5eed5eed5eed` | conversation | 7 | thumbIndexTap:3, thumbsUp:1, victory:1, wristRotateCCW:2 |
| `0x1111222233334444` | conversation | 7 | indexPoint:2, thumbIndexTap:5 |
| `0x8888777766665555` | conversation | 8 | thumbIndexTap:3, wristRotateCCW:2, wristRotateCW:3 |
| `0xa5a5a5a55a5a5a5a` | conversation | 10 | thumbIndexTap:5, thumbsUp:1, victory:1, wristRotateCCW:3 |
| `0x1` | typing | 100 | indexPoint:1, thumbIndexTap:33, thumbMiddleTap:28, thumbRingPinkyTap:8, thumbSwipeBackward:4, thumbSwipeForward:4, wristRotateCCW:13, wristRotateCW:9 |
| `0x123456789abcdef0` | typing | 106 | indexPoint:1, thumbIndexTap:41, thumbMiddleTap:26, thumbRingPinkyTap:10, thumbSwipeBackward:4, thumbSwipeForward:1, twoFingerScrollDown:1, twoFingerScrollUp:1, victory:1, wristRotateCCW:9, wristRotateCW:11 |
| `0x7e1711161dea1001` | typing | 106 | indexPoint:4, thumbIndexTap:38, thumbMiddleTap:31, thumbRingPinkyTap:6, thumbSwipeBackward:5, thumbSwipeForward:2, thumbsUp:1, wristRotateCCW:10, wristRotateCW:9 |
| `0x5eed5eed5eed5eed` | typing | 101 | indexPoint:1, thumbIndexTap:38, thumbMiddleTap:32, thumbRingPinkyTap:9, thumbSwipeBackward:1, thumbSwipeForward:3, thumbsUp:1, twoFingerScrollDown:1, wristRotateCCW:6, wristRotateCW:9 |
| `0xdeadbeefcafef00d` | typing | 118 | indexPoint:2, thumbIndexTap:40, thumbMiddleTap:23, thumbRingPinkyTap:14, thumbSwipeBackward:5, thumbSwipeForward:2, thumbsUp:2, twoFingerScrollDown:1, twoFingerScrollUp:1, wristRotateCCW:13, wristRotateCW:15 |
| `0xffffffffffffffff` | typing | 103 | indexPoint:1, thumbIndexTap:39, thumbMiddleTap:25, thumbRingPinkyTap:9, thumbSwipeBackward:7, thumbSwipeForward:3, thumbsUp:1, twoFingerScrollUp:1, wristRotateCCW:8, wristRotateCW:9 |
| `0x9e3779b97f4a7c15` | typing | 104 | indexPoint:3, thumbIndexTap:40, thumbMiddleTap:27, thumbRingPinkyTap:7, thumbSwipeBackward:2, thumbSwipeForward:3, wristRotateCCW:15, wristRotateCW:7 |
| `0xbadf00d600dc0de` | typing | 103 | indexPoint:3, thumbIndexTap:43, thumbMiddleTap:24, thumbRingPinkyTap:9, thumbSwipeBackward:3, thumbSwipeForward:3, wristRotateCCW:6, wristRotateCW:12 |
| `0x8888777766665555` | typing | 109 | indexPoint:1, palmTiltRight:1, thumbIndexTap:38, thumbMiddleTap:29, thumbRingPinkyTap:7, thumbSwipeBackward:4, thumbSwipeForward:1, twoFingerScrollDown:2, victory:1, wristRotateCCW:14, wristRotateCW:11 |
| `0xa5a5a5a55a5a5a5a` | typing | 95 | indexPoint:3, thumbIndexTap:32, thumbMiddleTap:27, thumbRingPinkyTap:9, thumbSwipeForward:1, wristRotateCCW:13, wristRotateCW:10 |
| `0x1111222233334444` | typing | 105 | indexPoint:3, thumbIndexTap:38, thumbMiddleTap:20, thumbRingPinkyTap:8, thumbSwipeBackward:4, thumbSwipeForward:4, thumbsUp:1, twoFingerScrollUp:1, wristRotateCCW:12, wristRotateCW:14 |

### What this does and does not establish

- It **does** establish that the shipped `requiresClutch = false` default has no working
  false-positive brake against this noise model, seed-independently (22/22).
- It is **still synthetic.** `Tests/Fixtures/` does not exist, so there is no recorded-hand
  evidence in either clutch mode. The four recorded legs now report `skipped:` with a reason
  rather than passing vacuously — a green run can no longer be misread as real-hand evidence.
- It is a **controlled** comparison despite being synthetic: same streams, same chain, same
  seeds, only `requiresClutch` differs, and the clutch-on legs stay at zero.

**This is the input to item (f)** (reopen the clutch-off default / add an `openPalm`
panic-disarm), which remains out of scope for this pass.


## New finding from (d) — hold-release gates on the decider, not on the key

**Not a reachable bug today. Logged for a deliberate decision, deliberately NOT fixed in the
test-fixing commit.**

Both stuck-key release paths gate on `holdTracker`, not on whether a key is physically down:

```swift
endActiveHoldIfNeeded()           guard let event = holdTracker.reset() else { return }
handleApplicationWillTerminate()  guard holdTracker.reset() != nil     else { return }
```

`activeHoldChord` is the thing that holds a real key down (set in `handleHoldBegan`, cleared in
`releaseActiveHold`'s `defer`). `holdTracker` is a pure decider. The guard asks *"did we think a
hold was active?"* when the safety-critical question is *"is a key still down?"*

**Why it is not reachable now:** `apply(_:generation:timestamp:)` is the only caller of
`holdTracker.ingest`, and it calls `handleHoldEvent(_:)` on the very next line, so the two states
cannot desync in the shipped app. Confirmed by grep, and independently triangulated by two agents
from two different test files.

**Why it is still worth deciding:** one refactor that separates those two lines turns this into a
real stuck key, and `endActiveHoldIfNeeded()`'s own doc comment already calls itself *"the single
chokepoint every non-pose-based hold-ended path routes through"* — the fifth comment in this file
found claiming something stronger than the code delivers.

**The fix, if wanted:** let `releaseActiveHold()` be the gate — call `holdTracker.reset()` for its
side effect, then release whenever `activeHoldChord != nil`. Preserve the existing
`hudController.endHold()` semantics (today it runs when the tracker had a hold even if no key-down
was ever posted). ~5 lines across two methods.

**Why it was not done here:** it changes production behaviour on a safety path. The failing tests
that surfaced it were asserting a stuck key the shipped app cannot produce, so making production
looser to satisfy an unreachable synthetic state would be fixing the wrong thing — the same
reasoning item (a) used when it refused to tune thresholds until the noise suite went green.

## Decisions
- **(a) lands red.** Failures are the deliverable. Do **not** raise
  `clutchOffConfidenceBoost`/`debounceFrames` to force green — that fits the synthetic noise
  generator, not real hands. Record actual event counts per gesture/stream/seed in this log.
- **Order is b → c → a → d → e.** (b) and (c) are small and independent; (a) is measurement;
  (d) retro-covers (b) and (c); (e) is sequenced last because it changes
  `ActionDispatcher.dispatch`'s signature and would churn any test written before it.
- **Keystroke posting stays synchronous on the main actor.** Ordering is the reason
  (`TacitEngine.swift:1036-1044` already argues this for holds/toggles); `CGEvent.post` is
  non-blocking so there is no latency cost.
- Docs live in `docs/CODE-REVIEW-2026-08-27.md`; this log stays short and current.

## Gotchas
- `./scripts/test.sh` is the runner (303 tests, 3 suites, ~0.6s at `ffe50da`). Needs no camera
  or permissions. Re-baseline against that number.
- `Tacit` is an `executableTarget` (`Package.swift:9`). Confirm SwiftPM on this toolchain allows
  a `testTarget` to depend on it before committing to that shape in (d); if it refuses, extract
  the engine into a third library target rather than fighting it.
- `TacitEngine.swift` is 1,800 lines and majority prose. Many doc comments assert invariants that
  are **not** tested — treat them as intent, not proof. Two were already wrong: the
  "never on the main actor" safety argument at `handleFire`'s dispatch site (finding 4) and the
  ordering rule around `:1036-1044` that `handleFire` itself broke (finding 5). (c) rewrote the
  former to state the real invariant (ordering vs. blocking) and made the latter true again —
  `handleFire` now follows its own stated rule for keystroke-shaped actions. Finding 4's blocking
  calls (`.runShortcut`/`.focusTextInput`/`.switchApp`) are still unfixed — that's (e), not (c).
- `ArbitrationEngine` in clutch-off mode is `.armed(.infinity)` from construction
  (`ArbitrationEngine.swift:136`). Any test asserting `!everArmed` is clutch-on-only by
  construction — don't port those assertions across.
- **The 303-green number overstates coverage.** `Tests/Fixtures/` does not exist, so both
  recorded-hand negative legs (`NegativeSuiteTests.swift:463, 478`) early-return and pass
  vacuously. All false-positive evidence is synthetic *and* clutch-on. Don't read green as
  "noise can't fire it."
- TCC keys Accessibility/Camera grants to the signing identity. Rebuilding via
  `./scripts/make-app.sh` without a stable Apple Development identity drops the grants every
  time; manual verification of (b)/(e) needs a real identity or repeated re-granting.
- Building the `.app` is only needed for manual verification. All five items are testable from
  `swift test` once (d)'s target exists.
