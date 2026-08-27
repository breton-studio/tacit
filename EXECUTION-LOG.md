# Tacit code-review remediation — execution log
Updated: 2026-08-27 · Branch: main · Status: in progress (nothing implemented yet)

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

## In flight
- Nothing. No source changes have been made. Working tree contains only these two new docs.

## Next
1. **(b) Persist the latched chord** — smallest, highest-value, no signature churn.
   `tacit.latchedChord` in `UserDefaults`; write on engage, clear on release, replay-and-clear in
   `TacitEngine.init`. See review §Finding 3.
2. **(c) Move `.keystroke` posting to the main actor** — split `handleFire`
   (`TacitEngine.swift:1393`) by action kind. Detach only Shortcut / AX / switchApp.
   See review §Finding 5.
3. **(a) Clutch-off negative suite** — parameterise `replayThroughFullChain`
   (`NegativeSuiteTests.swift:90`) over tuning, add clutch-off legs asserting only
   `events.isEmpty`. **Expected to fail. Land it red and record the counts here.**
   Also make the two vacuous recorded-fixture legs stop reporting green.
   See review §Finding 1.
4. **(d) `TacitTests` target** — inject `ActionEnvironment` through `TacitEngine.init`, spy the
   ordered key log, assert the seven invariants listed in the review. Also gives (b) and (c)
   their regression tests. See review §Finding 2.
5. **(e) Unblock the cooperative pool** — `dispatch(_:)` goes `async`; Process timeout, AX
   messaging timeout, drop `DispatchQueue.main.sync`. Largest, and the only public signature
   change — do it last. See review §Finding 4.

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
  are **not** tested — treat them as intent, not proof. Two are already wrong: the
  "never on the main actor" safety argument at `:1381-1388` (finding 4) and the ordering rule at
  `:1036-1044` that `handleFire` itself breaks (finding 5).
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
