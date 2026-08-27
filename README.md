# Tacit

A macOS menu bar app that watches your webcam for hand gestures and turns them into keystrokes, app switches, and other actions — no wearables, no clicking.

## TL;DR

- Tacit lives in the menu bar. It watches your hand through the built-in webcam, recognizes a gesture, and fires whatever you've bound to it — a keystroke, an app switch, opening a URL, running a Shortcut. Recognition runs entirely on-device via Apple's Vision framework; nothing leaves the Mac.
- Build and run it: `./scripts/make-app.sh && open build/Tacit.app`.
- Out of the box: thumb taps switch apps, a palm tilt switches apps, holding a point gesture dictates (Fn, for Wispr Flow-style push-to-talk), a victory sign toggles hands-free dictation, thumbs-up focuses a text field, and thumb swipes are undo/redo. Everything else ships off with a suggested binding.
- Two things people trip on: (1) keystroke actions need **Accessibility** permission, granted during first-run onboarding; (2) the **clutch** (a fist-hold "arm" gesture) is optional and **off by default** — gestures fire the moment they're recognized, at a stricter confidence floor, not after a fist hold.

## What it does

Tacit runs a webcam pipeline that detects your hand's 21 landmark points, classifies the shape or motion into one of 25 known gestures, and — if a gesture is enabled and clears arbitration (debounce, cooldown, confidence) — dispatches the action it's bound to. You never touch the keyboard or mouse to switch apps, undo, dictate, or fire a Shortcut; you just move your hand near the keys.

Every gesture maps to exactly one `TacitAction`. There are eight kinds, three of which are keystroke deliveries:

| Action | What it does |
|---|---|
| Keystroke — press | Posts a key down then up, like a normal keypress |
| Keystroke — hold | Key stays down for as long as the gesture is held, released when it ends |
| Keystroke — toggle | First fire presses the key down and latches it; the next fire (of the same chord) releases it |
| Launch app | Opens or activates an app by bundle ID |
| Open URL | Opens a URL in the default handler |
| Run Shortcut | Runs a named Shortcuts.app shortcut |
| Focus text input | Uses the Accessibility API to focus the frontmost window's main text field |
| Switch app | Activates the next/previous app directly via `NSRunningApplication` — no ⌘Tab, no switcher UI |

## Default gestures (revision 8)

These are the bindings a fresh install ships with (`MappingStore.defaultBindings()`, defaults revision 8). Everything not listed here is off, though several carry a suggested action you can just re-enable.

| Gesture | Action | Notes |
|---|---|---|
| Thumb–index tap | Previous app | |
| Thumb–middle tap | Next app | |
| Palm tilt left | Previous app | Lean the open hand left |
| Palm tilt right | Next app | Lean the open hand right |
| Index point (hold) | Hold Fn | Push-to-talk dictation — Wispr Flow's stock hotkey |
| Victory (✌️) | Toggle Fn | Hands-free dictation; fires once per pose, not per frame |
| Thumbs-up | Focus text input | |
| Thumb swipe backward | ⌘Z | Undo |
| Thumb swipe forward | ⇧⌘Z | Redo |
| Loose fist | *(reserved)* | The clutch gesture — not user-bindable |
| Open palm | *(reserved)* | The disarm gesture — not user-bindable |

Everything else — the four directional hand swipes, wrist rotate CW/CCW, two-finger scroll up/down, fist-to-open, pinch-drag, thumb–ring/pinky tap, palm push, wave, two-hand frame — ships disabled. Most still carry a suggested binding (e.g. fist-to-open suggests ⌘W) so turning one on gives you something reasonable immediately.

Change any of this in the Library (the specimen grid in the menu bar popover): pick a gesture, pick an action kind, and for keystrokes pick a delivery mode — press, hold, or toggle.

## Fatigue findings behind the gesture set

Tacit's gesture tiers and defaults come from the evidence review in [`docs/research/LowFatigue-Economic-Hand-Gestures.md`](docs/research/LowFatigue-Economic-Hand-Gestures.md). The strongest finding is not a particular pose: it is **keeping the forearm supported on the desk**. That removes most of the shoulder load behind “gorilla arm” fatigue. For gestures used dozens of times per hour, the research also favors a neutral wrist, relaxed adjacent fingers, near-zero force, and a quick return to rest.

**Lower-fatigue gestures** are brief thumb–index and thumb–middle taps, thumb swipes along the index finger, a loose point, thumbs-up, a loose fist, and a relaxed open palm. Tacit's short palm tilts follow the same small-motion principle. A pinch should be a light touch and immediate release, never a squeeze. Static poses cost the least motion, but are easier to trigger accidentally; short dynamic microgestures add a more distinctive motion signature without requiring a large arm movement.

**Higher-fatigue gestures** raise the arm, hold an awkward posture, or recruit more joints: palm pushes, waves, and especially the two-hand frame belong in the rare/deliberate tier. Full wrist rotation, a held flat splayed “halt” hand, isolated ring/pinky actions, and sustained or forceful pinches are also poor choices for frequent commands. They trade comfort for deliberate, low-false-positive input and should be reserved for occasional actions. Tacit's three most deliberate gestures — palm push, wave, and two-hand frame — are catalogued honestly but do not have detectors yet.

That trade-off shapes the factory defaults: most enabled commands use low-fatigue workhorses, while whole-hand swipes ship off and the smaller palm tilts handle app switching. The optional fist clutch can reduce accidental static-pose triggers; because it currently ships off, Tacit applies a stricter confidence floor instead.

These are design findings, not clinical claims or a finished Tacit user study. The source report synthesizes mid-air fatigue, hand-posture, microgesture, and webcam-detectability research; Tacit's recorded-fixture accuracy gate and Borg/NASA-TLX fatigue validation are still pending.

## The clutch (optional)

The clutch is a "hold a loose fist to arm" gesture that used to gate everything else, so a hand resting near the keyboard couldn't misfire a gesture. It's real and still built in, but it's **off by default** right now — an earlier build showed the fist read bouncing between `arming` and `disarmed` for real users, so gestures now fire the instant they're recognized instead.

To compensate, Tacit raises its confidence floor by a fixed amount whenever the clutch is off, so gestures still need a clean read to fire — just without the fist-hold step.

Turn the clutch back on with the "Require clutch (fist to arm)" toggle in the menu bar popover or the Library's Settings tab.

## Install & run

Requirements: macOS 15+, Xcode (for `swift build`), a Mac with a camera.

```
./scripts/make-app.sh
open build/Tacit.app
```

`make-app.sh` builds a release binary and signs it with your Apple Development (or Developer ID) identity if you have one installed — this keeps macOS's Accessibility/Camera grants stable across rebuilds, since TCC keys them to the signing identity. If no identity is found it falls back to ad-hoc signing with a warning; ad-hoc builds get a fresh signature every rebuild, so you'll have to re-grant permissions each time.

First launch walks you through onboarding: camera access, Accessibility access, and a look at the default bindings. Launch-at-login is turned on by default after that first run.

## Permissions & troubleshooting

- **Camera** is required for any recognition at all.
- **Accessibility** is required only for gestures bound to a keystroke action (or focus-text-input). Gestures bound to launching an app, opening a URL, running a Shortcut, or switching apps work without it.
- If you rebuilt before switching to a stable signing identity, or the app reports it still needs Accessibility, remove Tacit from System Settings → Privacy & Security → Accessibility and re-add it.
- Watch what Tacit is doing live:
  ```
  /usr/bin/log stream --process Tacit --level info --style compact --predicate 'subsystem == "studio.breton.tacit"'
  ```
  (Use the full path — plain `log` is a zsh builtin, not the system logging tool.)
- Click Tacit's menu bar icon, then flip "Show gesture debug view" to show or hide the small floating panel. It displays the live hand constellation, current reading and confidence, clutch state, and last action fired — useful for tuning your hand/camera setup against what Tacit is actually seeing.
- Sensitivity (Relaxed / Standard / Eager) lives in the Settings tab if gestures feel too twitchy or too reluctant.
- "Pause for an hour" in the popover suspends recognition without quitting the app; it flips to "Resume" while paused.
- If Tacit crashes (or is force-quit) while a hold or toggle keystroke like Fn is down, the key can be left stuck — tap the physical key once (Fn, usually) to release it; a normal quit releases it for you.

## How it works (for the curious)

```
camera → Vision hand pose (21 landmarks)
       → static pose classifier + dynamic detectors (swipes, rotate, scroll, pinch-drag, palm tilt)
       → arbitration (debounce, cooldown, optional clutch, confidence floor)
       → mapping store (gesture → action)
       → action dispatcher (CGEvent keystrokes, NSWorkspace app activation, AX focus, Shortcuts)
       → HUD (on-screen feedback)
```

`TacitCore` is a pure Foundation library — all the detection, classification, arbitration, and dispatch logic, with no AppKit/SwiftUI/Vision imports, covered by the test suite. `Tacit` is the SwiftUI/AppKit app: it owns the camera capture, the actual Vision requests, the menu bar UI, the Library, onboarding, and the live action environment (the AX calls and `NSWorkspace` calls `TacitCore` can't make on its own since it stays Foundation-only).

## Gesture previews & hb-motion

The looping cartoon-glove animations you see in the Library come from `hb-motion`, a separate sibling repo (`~/Developer/hb-motion`) — a standalone Blender pipeline that renders a scripted glove rig per gesture and exports HEVC-with-alpha `.mov` + poster `.png` pairs. Those get copied into `Sources/Tacit/Resources/previews/` (25 gestures × 2 files = 50 assets) as part of the app build. If a preview asset is ever missing, the Library falls back to Tacit's own constellation line-art instead of showing nothing.

The menu bar and popover-header glyph are built from [Lucide](https://lucide.dev)'s `hand` and `hand-fist` icons (ISC License); everything else — the HUD, the Library, the popover body — is Tacit's own constellation line-art.

## Development

```
./scripts/test.sh      # runs the TacitCoreTests suite — no camera or permissions needed
swift build             # plain debug build
./scripts/make-icon.sh  # regenerates Sources/Tacit/Resources/AppIcon.icns from code
```

As of this writing, `./scripts/test.sh` runs 303 tests, all green.

The spec lives at `docs/superpowers/specs/2026-08-23-tacit-design.md`; implementation plans are in `docs/superpowers/plans/`; `docs/NEXT-STEPS.md` tracks current status and the backlog.

Default bindings are versioned: `MappingStore.currentDefaultsRevision` is the current number, and `MappingStore.defaultsRevisions` is an ordered list of `DefaultsRevision` entries, each an old→new binding diff. To change a factory default for existing users, bump the revision and append an entry rather than editing `defaultBindings()` in place — that's what lets an existing install pick up the new default without clobbering a binding the user already customized away from the old default.

Holding ⌥ in the menu bar popover reveals a hidden fixture recorder for capturing labeled hand-landmark clips to `~/Documents/TacitFixtures/`, used to build and replay the test suite's recognition fixtures. It's present in every build, not just debug ones — the real-hand accuracy gate (≥90%) it feeds is still user-gated and hasn't been run yet.

## Status / known gaps

- Three gestures — `palmPush`, `wave`, `twoHandFrame` — have no detector yet. Their Library cards say so honestly rather than pretending they work.
- The four directional hand swipes are recognized and bindable but ship disabled — they weren't detecting reliably enough for everyone, so palm tilt took over app-switching duty instead.
- The glove renders from hb-motion are a work in progress (proportions, some poses read slightly off).
- No App Store build: this is a direct-download, non-sandboxed app, since keystroke synthesis (`CGEvent`) needs Accessibility and isn't sandbox-friendly. The action layer is deliberately seamed so a future sandboxed variant could drop just that piece.

## Author

Tacit is created by [Hoyd Breton](https://hoydbreton.com/).

## License

Tacit is available under the [MIT License](LICENSE). The Lucide-derived menu bar glyphs retain Lucide's ISC License as described in [Gesture previews & hb-motion](#gesture-previews--hb-motion) and `Sources/Tacit/LucideGlyphs.swift`.
