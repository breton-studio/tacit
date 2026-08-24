# Tacit — status & next steps (handoff, 2026-08-24)

Written mid-session as an account-switch handoff. The authoritative execution ledger (rulings, fix rounds, deferred minors) is at `.superpowers/sdd/2026-08-24-tacit-m4/progress.md` (gitignored, local-only); this doc carries the durable summary.

## Where the project is

**M1+M2 (tag `m2`), M3 (tag `m3`): shipped.** Full 23-gesture recognition with the fist-clutch trust model, 6 action types (incl. hold-keystroke and AX focus-text-input), workflow defaults (swipeRight→⌘Tab, swipeUp→focus text input, indexPoint-hold→Fn for Wispr Flow), Settings tab, low-light policy, specimen-book Library. 248 tests green.

**M4: functionally complete, one formality outstanding.** All 8 plan tasks done and task-reviewed (plan: `docs/superpowers/plans/2026-08-24-tacit-m4.md`):

- **hb-motion** (`~/Developer/hb-motion`, main @ `f6bb45e`): standalone Blender 5.2 animation service. Scripted cartoon-glove rig (bones named exactly as Tacit's `HandJoint` rawValues), pose/choreography engine, 23 gesture choreographies (lint 95/95), render pipeline (~10s/gesture), HEVC-with-alpha encoder (`tools/pngs2hevc`), `scripts/pipeline.sh --all`. All 23 `.mov`+`.png` committed in `dist/`.
- **tacit** (main @ `db3aad8`): `GesturePreviewView` (alpha-video loop / poster / hover-play, constellation fallback when assets absent), 46 preview assets bundled into `Tacit.app/Contents/Resources/previews`, Try-It sessions (10s window, checkmark verdict, per-gesture coaching hints, honest "still in the works" copy for the 3 detectorless gestures), `make-app.sh` bundling. The rebuilt app is running (relaunched with the final assets).
- Task 8 took 3 visual-polish fix rounds on thumbsUp (diagonal thumb → cuff-disc blob → off-center framing); final render verified by eye: centered 👍, nothing clipped. thumbSwipe forward/backward were redesigned to be visually distinguishable (motion-diff ≥2× the sanity floor).

## Remaining steps, in order

1. **Move the `m4` tag** — it points at `937e08c`, two commits behind the milestone tip `db3aad8`. Force-tag ops were permission-blocked for the agent session. Run manually:
   `cd ~/Developer/tacit && git tag -f m4 && git push -f origin m4`
2. **Final whole-milestone M4 review** — the per-task reviews all passed, but the closing cross-task review (seams between GesturePreviewView / TryItSession / real assets: PreviewAssets static URL cache correctness now that assets exist, player hygiene with 23 hover cards, dual loop players when Try-It opens over the detail hero, hb-motion `verify_weight_isolation` only checking the Glove object not the new separate Cuff object) was interrupted by an API spend limit mid-run. Re-dispatch it; diffs are pre-packaged at `.superpowers/sdd/2026-08-24-tacit-m4/review-e4a00f4..db3aad8.diff` (tacit) and `review-hbmotion-m4.diff` (hb-motion code, binaries excluded). Its partial run already confirmed 248 tests green and the 46-file bundle. Then run one fix wave for any findings, and update the memory file + delete the SDD workspace.
3. **Manual smoke test** (2 min, human eyes): open the Library window — cards should show animated glove loops on hover, the detail hero should loop, "Try It" should give a checkmark when you perform the gesture and a coaching hint on timeout, and Esc should work in the overlay.

## Deferred minors (ledgered, ship-with-note)

- Call `AVPlayerLooper.disableLooping()` before player teardown; cache the decoded poster `NSImage` (currently re-decoded per render on hover fallback).
- hb-motion: thumbSwipe motion-diff margins now ≥2× floor but EEVEE nondeterminism could still flake on other hardware; palm silhouette reads circular rather than mitten-like (mesh work, risky); victory V slightly narrow; pngs2hevc has benign Swift 6 concurrency warnings + deprecated sync probe APIs.
- `Tests/Fixtures/` is still empty — the ≥90% real-hand accuracy gate has never run (⌥ in the popover reveals the recorder). User-gated.

## Post-M4 backlog

- **Detectors for palmPush, wave, twoHandFrame** — no detector exists for these three (pinned by test `detectorBackedGesturesIsEveryGestureExceptTheThreeWithNoDetector`); their cards honestly say recognition is in the works. palmPush needs depth/scale, wave needs oscillation, twoHandFrame needs two-hand tracking.
- Real-hand fixture recording + accuracy gate.
- hb-motion as a reusable service for other projects (already standalone; README documents the pipeline).

## How to resume

Both repos are clean and pushed. Rebuild/relaunch: `cd ~/Developer/tacit && ./scripts/test.sh && ./scripts/make-app.sh && open build/Tacit.app`. Re-render any gesture: `cd ~/Developer/hb-motion && bash scripts/pipeline.sh <id> --force` (Blender 5.2 at /Applications; Superhive/ARP token in gitignored `.secrets/`).
