# Tacit — Design Specification

**Date:** 2026-08-23
**Status:** Approved pending final user review
**Sources:** `docs/research/LowFatigue-Economic-Hand-Gestures.md` (ergonomics), `docs/research/Mac-Gestures-App-tech.md` (stack). Both reports are normative inputs to this spec.

---

## 1. What Tacit is

Tacit is a native macOS menu bar app that watches the built-in webcam for hand gestures and fires user-configured actions. It launches at login, runs quietly in the menu bar, and can be tuned or paused from there. Its gesture vocabulary is the 20 evidence-based gestures from the ergonomics report, each individually enable-able and bindable to one of four action types.

**Concept (binding, not decorative):** *your hand vocabulary, presented like a typeface specimen.* The app's one proprietary visual element is the **constellation** — line-art rendered from the actual 21 Vision hand landmarks, drawn from real capture data. It is the identity: menu bar glyph, HUD, specimen cards, empty states, app icon. The generative constraint from the research — **the forearm never leaves the desk** — stays visible in the product: gestures are grouped and labeled by ergonomic tier, and the app tells you which gestures are built for resting arms.

**Name:** Tacit — tacit knowledge; what hands know without words.

### Non-goals (v1)
- No per-app or switchable profiles (mapping store is shaped to allow them later).
- No App Store build (action layer is architected so a sandboxed variant can split off later).
- No custom ML training; geometric heuristics + temporal state machines only. Create ML hand-pose/action classifiers are a v2 escape hatch if heuristics prove insufficient.
- No precision Z-axis input; the palm-push gesture is a coarse binary confirm only.
- No live video as a primary UI surface; camera preview appears only in calibration/teaching contexts.

---

## 2. Product decisions (settled with user)

| Decision | Choice |
|---|---|
| Gesture vocabulary | Full 20-gesture library from the ergonomics report, per-gesture enable/disable |
| Action types | Keystroke (CGEvent), Launch/focus app (NSWorkspace), Open URL/deep link, Run macOS Shortcut |
| Feedback | Menu bar glyph states + subtle auto-dismissing HUD |
| Distribution | Direct-download first: notarized Developer ID, **non-sandboxed**. Action layer behind a protocol seam for a future sandboxed App Store variant (which would drop keystroke synthesis) |
| Mapping scope | One global gesture→action map in v1; data model profile-ready |
| Platform | macOS 15+, Swift 6, SwiftUI, Xcode project at `~/Developer/tacit` |

---

## 3. Architecture

Seven units. Each has one purpose, a defined interface, and is testable in isolation. The recognition core (§3.3–3.4) is pure — no camera, no UI — so it can be developed and verified entirely against recorded fixtures.

```
AVCaptureSession ──► CaptureEngine ──► HandPoseDetector ──► GestureClassifier ──► ArbitrationEngine ──► ActionDispatcher
                        (frames)         (LandmarkFrame)      (GestureCandidate)     (GestureEvent)         (side effects)
                                                                                          │
                                              UI layer (menu bar, HUD, library) observes every stage
                                              MappingStore feeds ArbitrationEngine + ActionDispatcher
```

### 3.1 CaptureEngine
- `AVCaptureSession` at 1280×720, `AVCaptureVideoDataOutput` on a dedicated dispatch queue.
- Inference throttle: minimum inter-inference interval targeting ~15 Hz; capture device min/max frame duration set at the source.
- Camera selection (built-in FaceTime camera default; picker for external/Continuity).
- Mirroring corrected before landmarks leave this layer, so "left swipe" means the user's left everywhere downstream.
- Publishes lifecycle state: `running / paused(reason) / unavailable(reason)`. Reasons include user-paused, camera-in-use-elsewhere, screen locked, low-light.

### 3.2 HandPoseDetector
- One `DetectHumanHandPoseRequest` (modern Swift Vision API), `maximumHandCount = 1`; raised to 2 only while a two-hand gesture (gesture 20) is enabled.
- Joints with confidence < 0.3 discarded.
- Output: `LandmarkFrame` — timestamp + normalized 21-point layout + per-joint confidence + handedness. `LandmarkFrame` is `Codable`; this is the fixture format (§8).

### 3.3 GestureClassifier (pure functions, no dependencies)
- **Static poses** via geometric rules: finger extended iff TIP farther from wrist than PIP (with hysteresis margin); pinch iff normalized thumb-tip↔target-tip distance < threshold; palm orientation from landmark plane.
- **Dynamic gestures** via temporal state machine over a rolling window: velocity-thresholded directional swipes, fist→open release, pinch-drag (pinch engaged = clutch, hand translation = value), wrist-rotate arc (partial arc only, per ergonomics report), thumb-swipe-along-index.
- Output: `GestureCandidate(gestureID, confidence, timestamp)` stream.
- Every one of the 20 gestures from the report's summary table is implemented; the report's IDs 1–20 are the canonical `gestureID`s.

### 3.4 ArbitrationEngine (the trust layer)
- **Clutch:** loose-fist hold ~400 ms arms the system → command window (default 4 s, re-extended by each recognized gesture) → auto-disarm. Open palm disarms immediately. Clutch state is exposed to UI.
- **Debounce:** a candidate must persist 3 consecutive inference frames before firing.
- **Hysteresis:** higher confidence to enter a pose state than to remain in it.
- **Cooldown:** 800 ms per gesture after firing; one gesture = one action.
- **Toggle rule:** paired/toggle actions use the identical gesture for both states (Chan 2016).
- Output: confirmed `GestureEvent`s. Nothing fires while disarmed except the clutch itself.
- All thresholds live in one `ArbitrationTuning` value type — user-adjustable later, fixture-testable now.

### 3.5 ActionDispatcher
- `protocol TacitAction: Codable { func perform() async throws; var requiresAccessibility: Bool { get } }`
- Five conformers: `KeystrokeAction` (CGEvent virtual key + modifier flags, posted to `.cghidEventTap`), `LaunchAppAction` (`NSWorkspace.openApplication`), `OpenURLAction` (any URL scheme, e.g. `superwhisper://record`), `RunShortcutAction` (`Process` → `shortcuts run "Name"`), `SwitchAppAction` (2026-08-24: activates the next/previous app directly via `NSRunningApplication.activate` on a frozen, MRU-first `AppSwitchRing` — never posts ⌘Tab, never shows the system switcher). Keystrokes come in three modes: *press* (down+up), *hold* (down while a holdable pose is held), and *toggle* (down on one fire, up on the next — a latch owned by the engine, released on any capture stop, quit, or rebind).
- **This protocol is the App Store seam:** a future sandboxed target ships the same dispatcher minus `KeystrokeAction`.
- Dispatch failures surface as HUD-level errors, never silent.

### 3.6 MappingStore
- Observable; persisted as versioned JSON in `~/Library/Application Support/Tacit/mappings.json`.
- Schema: `{ version, mappings: [gestureID: { enabled, action }] }` — flat now, trivially wrappable in named profiles later.
- Ships with sensible defaults from the ergonomics report's example maps, all *disabled* except the workhorse core so first-run is calm (defaults **revision 5**, 2026-08-24): thumb-index tap → ⌘C, thumb-middle tap → ⌘V, thumbs-up → focus text input, thumb-swipe-on-index → undo/redo (⌘Z / ⇧⌘Z), index-point *hold* → Fn (push-to-talk dictation), victory → *toggle* Fn (hands-free dictation — moved off thumb–ring/pinky tap in revision 5, since that tap physically overlaps the index-point pose), swipe right/left → next/previous app (`.switchApp`, direct `NSRunningApplication.activate`, never ⌘Tab). Thumb–ring/pinky tap ships *disabled* with no suggested action. Every other dynamic gesture ships off. Default *values* are versioned separately from the wire format: a `DefaultsRevision` chain rewrites only bindings still exactly equal to the previous default. Loose fist (clutch) and open palm (disarm) are reserved system gestures and cannot be bound.

### 3.7 UI layer
- **Menu bar** (`MenuBarExtra`): constellation glyph with four states — *paused* (hollow), *watching* (idle line-art), *armed* (accent-filled), *fired* (single brief pulse). Popover: master toggle, arm/disarm, "Pause for an hour," launch-at-login toggle, "Open Library," warning row (low light / permissions), quit.
- **HUD**: non-activating `NSPanel`, small, centered-lower like the system volume HUD. Shows the fired gesture's constellation + action name; auto-dismisses. Never steals focus, never accepts clicks.
- **Library window**: the specimen book (§5).
- **Onboarding**: camera permission → accessibility permission (`AXIsProcessTrustedWithOptions`) → teach the clutch (perform it live) → bind first gesture. Each step skippable; app degrades gracefully (no accessibility = keystroke actions disabled with notice).
- **ConstellationRenderer**: one shared SwiftUI renderer taking a `LandmarkFrame` (live or canned) → line-art. Used by glyph, HUD, cards, icon assets.
- Launch-at-login via `SMAppService.mainApp`, default **on**, toggleable in popover and Library.

---

## 4. Visual system (binding rules for all UI work)

All UI work in this project is governed by three loaded skills — `hb-crafting-interface-experiences` (nine principles + quality floor), `hb-design-eng` (goal-first / lighter / system-as-listener lenses, frequency gate), and the creative-director concept above. Implementation agents MUST treat the following as acceptance criteria:

1. **Palette:** near-monochrome (label/secondary-label hierarchy over system materials). Exactly **one accent** color, used solely for the *armed/active* semantic state. Color carries semantic load, never decoration. Full dark/light support via system dynamic colors.
2. **Constellation identity:** all gesture imagery is rendered by `ConstellationRenderer` from real landmark data — never SF Symbol hands, never stock illustrations. Line weight consistent (hairline joints, 1.5pt bones at 1×); joints as small dots, bones as lines.
3. **Typography:** system font (SF Pro) with deliberate hierarchy; **tabular numerals and small-caps-style metadata labels** for the ergonomic ratings on cards. No custom display face in v1.
4. **Transient surfaces are weightless:** HUD and popovers use system materials (`.ultraThinMaterial`/`NSVisualEffectView` equivalents), hairline borders, soft shadows — never opaque slabs.
5. **Motion tokens** (project-wide constants in `TacitMotion.swift`; agents use tokens, never magic numbers):
   - `pressFeedback`: `.spring(duration: 0.16, bounce: 0)` — pressables scale to 0.97
   - `standardUI`: `.spring(duration: 0.25, bounce: 0)` — tray/section transitions
   - `hudIn`: `.spring(duration: 0.20, bounce: 0)`; `hudOut`: ~20% faster, ease-out fade
   - `armedPulse`: `.spring(duration: 0.30, bounce: 0.15)` — the one place subtle life is allowed
   - `signature`: `.spring(duration: 0.45, bounce: 0.15)` — reserved for rare moments (onboarding completion, first successful gesture)
6. **Quality floor (non-negotiable):** Reduce Motion honored on every animation (fade/instant fallback); contrast ≥ 4.5:1 body text; hit targets ≥ 44×44 pt; visible keyboard focus on every interactive element; all animations interruptible (value-driven springs, no timers).

### Motion spec (seven-field, per animated element)

| Element | Trigger | Properties | Duration | Easing/spring | Stagger | Origin | Reduced-motion |
|---|---|---|---|---|---|---|---|
| Menu bar glyph watching→armed | clutch recognized | line-art fill opacity, accent | 200 ms | `standardUI` | — | in place | instant swap |
| Menu bar glyph fired pulse | gesture fired | scale 1→1.06→1 | 300 ms | `armedPulse` | — | center | none (glyph state change suffices) |
| HUD in | gesture fired | opacity 0→1, scale 0.97→1, translateY 6→0 | 200 ms | `hudIn` | — | rises from bottom-center resting position | opacity fade only |
| HUD constellation draw-on | HUD appears | stroke trim 0→1 | 250 ms (concurrent with HUD in) | ease-out | — | wrist joint outward | full stroke, no draw |
| HUD out | 800 ms dwell elapsed | opacity 1→0, scale →0.98 | 160 ms | ease-out | — | in place | opacity fade |
| Popover open | menu bar click | system default | system | system | — | menu bar item | system |
| Specimen card → detail | card click | card expands in place | 250 ms | `standardUI` + `matchedGeometryEffect` | — | the clicked card (object permanence — same element travels) | crossfade |
| Card grid first appearance | window open | opacity 0→1, translateY 8→0 per card | 200 ms each | ease-out | 30 ms/card, capped 300 ms total | — | no stagger, single fade |
| Perform-to-preview live skeleton | user's hand | landmark positions | continuous | `.interactiveSpring` smoothing | — | tracks the hand (system-as-listener) | unchanged (user-driven, essential) |
| Enable toggle, action save | toggle/click | system toggle + 150 ms confirmation tick | ≤150 ms | ease-out | — | control | instant |
| Onboarding clutch success | first armed clutch | constellation draw-on + accent bloom | 450 ms | `signature` | — | user's rendered hand | fade + text confirmation |

**Frequency-gate rulings (binding):** gesture *firing* happens dozens of times an hour — HUD stays ≤ 200 ms in, no bounce, and users can disable the HUD entirely while keeping glyph feedback. Keyboard-initiated things (none in v1's UI) never animate. The signature budget is spent exactly twice: onboarding clutch success and first-ever successful mapped gesture.

**Interaction stance (system-as-listener):** Tacit never performs at the user. No autoplaying loops, no infinite pulses, no attention-seeking badge motion. The armed state is the *user's* doing (they clutched); the UI answers it. The one persistent motion allowed is the live skeleton in perform-to-preview, which is user-driven by definition.

---

## 5. The Library window (specimen book)

- Single window, three sections in fixed editorial order: **Workhorses** (report gestures 1–8: static, desk-resting), **Occasional** (9–17: dynamic), **Deliberate** (18–20: free-air, rare). Section headers carry one-line editorial notes derived from the research ("Built for a resting arm. Use these for anything you do dozens of times an hour.").
- **Specimen card** (the unit of the interface): constellation drawing of the gesture, name, and quiet metadata line — comfort tier, false-positive risk, static/dynamic — set in small tabular type. Enable toggle. Current binding shown as "fires → ⌘C" style summary.
- **Card detail** (expands from the card, `matchedGeometryEffect`; context preserved, no navigation push): action binder (segmented by the four action types — keystroke recorder, app picker, URL field with validation, Shortcut picker via `shortcuts list`), sensitivity note, and **perform-to-preview**: a small live camera strip with skeleton overlay where performing the gesture lights the card up — teaching and testing in one move (Cooper: collapse thinking and making).
- Empty/degraded states get full polish: no camera permission → the constellation glyph literally missing joints with a plain-verb fix-it button; low light → the card art dims with a one-line explanation.
- Settings that aren't gesture-specific (camera picker, launch at login, HUD on/off, arbitration sensitivity global trim) live in a compact Settings tab in the same window.

---

## 6. Trust, errors, and degradation

Everything fails toward *paused and saying so* — never toward silently firing or silently dying.

| Condition | Behavior |
|---|---|
| Low light detected (mean luma below threshold for >5 s) | glyph gains warning dot; popover row explains; recognition continues but arbitration raises thresholds |
| Camera claimed by another app | auto-pause with reason; auto-resume when free |
| Screen locked / display asleep | detection paused |
| Accessibility permission missing/revoked | only `KeystrokeAction`s disabled; affected cards show notice + re-grant button |
| Hand out of frame during perform-to-preview | inline guidance in the preview strip |
| Action dispatch failure | HUD shows the failure in plain verbs ("Couldn't run Shortcut 'Focus'") |
| Sustained misrecognition (confidence collapse) | system disarms; requires fresh clutch |

Privacy stance (also marketing truth): all processing on-device via Apple Vision; no frame ever persisted except explicit user-initiated fixture recordings; no network calls at all in v1.

---

## 7. Permissions & system integration

- **Camera** (`NSCameraUsageDescription`) — onboarding step 1.
- **Accessibility** (for CGEvent posting) — onboarding step 2, via `AXIsProcessTrustedWithOptions`, skippable.
- **Launch at login** — `SMAppService.mainApp`, default on, surfaced in popover + settings.
- Non-sandboxed, Hardened Runtime on, Developer ID signed, notarized (M5 milestone).
- No Screen Recording permission in v1 (screenshot mappings synthesize ⌘⇧4 rather than capturing).

---

## 8. Testing strategy

**The recognition core is fixture-driven.** `LandmarkFrame` is Codable; a debug-menu recorder captures real sessions to JSON fixtures in `Tests/Fixtures/`. Sonnet swarm agents TDD the classifier and arbitration engine entirely against fixtures — no camera, no human in the loop.

- **GestureClassifier:** per-gesture fixture suites — positive captures, near-miss confusables (victory vs point, loose fist vs resting hand), and typing-hands negative footage. Target: ≥90% recognition on positives, zero fires on the typing-negative reel.
- **ArbitrationEngine:** state-machine unit tests — clutch timing, debounce counts, cooldown, hysteresis, command-window expiry — plus a Midas-touch suite replaying long negative fixtures (acceptance: <1 false arm/hour equivalent).
- **MappingStore:** round-trip, schema-version migration, corrupt-file recovery.
- **ActionDispatcher:** conformer tests with injected posting/launching mocks; `requiresAccessibility` gating.
- **UI:** snapshot tests for glyph states and card layouts where cheap; the motion spec table in §4 is the review checklist for hand-verification.
- **Human acceptance gates** (run by the user + Fable at milestones, thresholds from the ergonomics report): clutch false-arms < 1/hour in normal desk use; per-gesture accuracy ≥ 90%; 30-minute session comfort (Borg CR10 ≤ 2, informal); dynamic-gesture false positives during typing < 1/hour.

Initial fixtures are recorded by the user during M1 (the debug recorder is therefore an M1 deliverable, built early).

---

## 9. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M1 — Skeleton & clutch** | App shell, capture, detector, clutch arbitration, menu bar glyph 4 states, fixture recorder, launch-at-login | Clutch arms/disarms reliably; fixture recording works; false-arm rate measured |
| **M2 — Workhorses** | Gestures 1–8, MappingStore + defaults, ActionDispatcher (all 4 types), HUD, Library window with cards + binding + perform-to-preview, onboarding | Bind and fire copy/paste/tab-switch end to end; motion spec implemented |
| **M3 — Dynamic layer** | Gestures 9–17 (temporal state machine), sensitivity trim, low-light handling | Typing-negative suite passes; swipes usable |
| **M4 — Deliberate tier** | Gestures 18–20 (incl. two-hand), onboarding polish, empty/degraded states to full polish floor | All 20 gestures live; polish floor audit passes |
| **M5 — Harden & ship** | Notarization, energy audit (inference Hz tuning), Reduce Motion audit, final critique pass against `assets/critique-rubric.md` | Notarized build installed and running at login on user's machine |

---

## 10. Execution model

- Repo: `~/Developer/tacit` (this repo; GitHub `breton-studio/tacit`, private). Xcode project generated in M1.
- After user approval of this spec: invoke **superpowers:writing-plans** → detailed implementation plan → execute via **subagent-driven development** with **Sonnet 5** worker agents.
- Parallel tracks per milestone where dependencies allow: (a) capture/detection, (b) classifier/arbitration fixture-TDD, (c) actions/mapping, (d) UI, (e) system integration. Fable 5 (session lead) integrates, reviews every merge against this spec's §4 binding rules and the loaded craft skills, and runs milestone gates with the user.
- Worker agents are instructed to read this spec §4–§5 verbatim before any UI task; motion values come from `TacitMotion.swift` tokens only.

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Vision's Tahoe 26 hand-pose model shifts joint locations | Heuristics use relative geometry (ratios, distances), not absolute positions; thresholds in one tunable struct; fixtures re-recordable |
| Desk-resting hands seen edge-on by the high webcam | Onboarding teaches the slight-lift hand position; perform-to-preview gives immediate feedback; low-confidence handling degrades gracefully |
| Midas touch despite clutch | Debounce/hysteresis/cooldown are all tunable; M1 measures before M2 expands vocabulary |
| CGEvent + non-sandbox complicates future App Store ambition | `TacitAction` protocol seam isolates it; documented in §3.5 |
| 20 gestures overwhelm tuning effort | Milestones stage the vocabulary exactly as the ergonomics report's rollout plan prescribes; defaults ship mostly disabled |
