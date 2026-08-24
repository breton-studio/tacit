# Tacit

Tacit is a macOS menu bar app that watches the built-in webcam for hand gestures and fires
whatever action you've bound to each one — a keystroke, launching an app, opening a URL, or
running a Shortcut. Recognition runs entirely on-device with Apple Vision; nothing leaves the
machine. A clutch gesture (hold a loose fist) gates everything else, so gestures only fire while
you've deliberately armed the system — resting your hand near the keyboard never triggers anything
on its own.

## Build

```
./scripts/make-app.sh
```

Produces `build/Tacit.app`, ad-hoc signed, ready to launch or move to `/Applications`.

## Run

Launch `build/Tacit.app`, or run it straight from Xcode/`swift run` during development. On first
launch Tacit walks through a short onboarding: camera permission, Accessibility permission,
learning the clutch, and binding one gesture. Tacit lives in the menu bar from then on — click the
glyph for the master toggle, "Pause for an Hour," launch-at-login, and the gesture library.

## Test

```
./scripts/test.sh
```

Runs the `TacitCoreTests` suite — unit and integration tests for detection, classification,
arbitration, and dispatch, all against synthetic or recorded hand-landmark data. No camera or
permissions are needed to run the tests.

## Permissions

- **Camera** — required for any recognition at all; requested during onboarding.
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
