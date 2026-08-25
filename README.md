# Tacit

Tacit is a macOS menu bar app that watches the built-in webcam for hand gestures and fires
whatever action you've bound to each one — a keystroke, launching an app, opening a URL, or
running a Shortcut. Recognition runs entirely on-device with Apple Vision; nothing leaves the
machine. A clutch gesture (hold a loose fist) gates everything else, so gestures only fire while
you've deliberately armed the system — resting your hand near the keyboard never triggers anything
on its own. Alongside the static poses sits a dynamic layer — directional swipes, a fist-opening
flourish, and continuous rotate and two-finger-scroll gestures that tick repeatedly while you hold
them — for actions that read more naturally as a motion than a shape. In dim rooms Tacit quietly
raises its own confidence thresholds rather than firing on noise, and says so in the menu bar until
the light comes back.

Gesture previews are rendered by hb-motion, a standalone Blender pipeline (separate repo) that
exports a looping cartoon-glove animation per gesture into `Sources/Tacit/Resources/previews/`.

## Build

```
./scripts/make-app.sh
```

Produces `build/Tacit.app`, signed with your stable Apple Development (or Developer ID) identity when one is available — falling back to ad-hoc signing with a warning otherwise — ready to launch or move to `/Applications`; if you're switching from a previous ad-hoc build or a different certificate, you'll need to re-grant Accessibility (and possibly Camera) once in System Settings.

## Run

Launch `build/Tacit.app`, or run it straight from Xcode/`swift run` during development. Tacit
requests camera permission at launch, alongside a short first-run onboarding: Accessibility
permission, learning the clutch, and a look at the preset gesture bindings you start with — among
them the workflow defaults: tilt your open palm left/right to flip apps — lean right → next, lean
left → previous, directly (no ⌘Tab, no switcher UI; the hand swipes still recognize but ship off,
since they weren't being detected reliably for everyone) — a thumb–middle tap → next app,
thumb–index tap → previous app (palm tilts do the same), a thumbs-up focuses the nearest text
field, holding a point gesture holds
down Fn — Wispr Flow's stock push-to-talk hotkey — and a victory (✌️) sign *toggles* Fn for
hands-free dictation until you make it again (the menu bar popover shows a "Release" row while it's
held). Undo and redo ride the thumb swipes. Everything else ships off;
every binding is rebindable in the Library, where a keystroke can be delivered as a press, a hold,
or a toggle. The
clutch itself is optional and off by default for now — gestures fire the moment they're
recognized, at a stricter confidence floor — with a "Require clutch (fist to arm)" toggle in the
popover and Settings tab for anyone who wants the fist hold back.
Tacit lives in the menu bar from then on — click the glyph for the master toggle, "Pause for an Hour,"
launch-at-login, and the gesture library, which also holds a Settings tab for picking a camera and
trimming overall gesture sensitivity. Flip "Show gesture debug view" in the popover for a small
floating panel showing the live constellation, raw classifier reading, and clutch state, so you can
tune your hand/camera against what Tacit is actually seeing.

## Test

```
./scripts/test.sh
```

Runs the `TacitCoreTests` suite — unit and integration tests for detection, classification,
arbitration, and dispatch, all against synthetic or recorded hand-landmark data. No camera or
permissions are needed to run the tests.

## Permissions

- **Camera** — required for any recognition at all; requested at launch, alongside onboarding.
- **Accessibility** — required only for gestures bound to a keystroke action (`CGEvent` posting).
  Gestures bound to launching an app, opening a URL, or running a Shortcut work without it. If
  Accessibility is missing or revoked, Tacit says so in the menu bar and in the Library rather than
  failing silently.

## Fixture recording (debug builds)

Holding ⌥ in the menu bar popover reveals a hidden section for recording labeled hand-landmark
clips to `~/Documents/TacitFixtures/`, used to build and replay the test suite's recognition
fixtures. It's a developer tool, not a product feature — it has no effect on normal use, but it is
present in every build (there's no separate debug configuration gating it), so it's always just an
⌥ away if you need to capture a new fixture.

## Credits

The menu bar/popover-header glyph is built from [Lucide](https://lucide.dev)'s `hand` and
`hand-fist` icons (ISC License); everything else (HUD, Library, popover body) keeps Tacit's own
constellation line-art.
