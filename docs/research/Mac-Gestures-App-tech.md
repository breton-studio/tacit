# Hand-Gesture Webcam Control on macOS: The Best Developer Stack for an M5 Max MacBook Pro

## TL;DR
- **Build a native Swift/SwiftUI menu-bar app on Apple's Vision framework (`DetectHumanHandPoseRequest`), not a Python/MediaPipe app** — it is on-device, Neural-Engine-accelerated, ships in the OS, needs no bundled runtime, and integrates cleanly with the CGEvent/NSWorkspace/URL-scheme APIs you need to trigger Ghostty and Superwhisper. Reserve MediaPipe only for fast prototyping or if you specifically need true 3D landmarks.
- **Use static poses for your command vocabulary, not dynamic swipes** — both Vision and MediaPipe return 21 hand landmarks, and distinct static poses (open palm, fist, "peace"/victory, thumbs-up, pinch, finger-counts 1–5) are recognized far more reliably and with lower false-positive rates than motion gestures. Layer confidence thresholds + N-frame debouncing + a cooldown to make triggers rock-solid.
- **Trigger actions with the right macOS API per target:** launch Ghostty with `NSWorkspace.openApplication`; control Superwhisper with its official `superwhisper://record` / `superwhisper://mode?key=` deep links (or its start/stop-recording deep links); synthesize any hotkey with `CGEvent`. You will need Camera and Accessibility (and, for a screenshot gesture, Screen Recording) permissions.

## Key Findings

1. **Apple Vision is the correct foundation on this hardware.** `DetectHumanHandPoseRequest` (modern Swift API; `VNDetectHumanHandPoseRequest` is the legacy Obj-C name) returns 21 landmarks per hand (4 per finger + 1 wrist), runs on the Neural Engine/GPU, and at WWDC25 Apple shipped a modernized hand-pose model. Per Apple engineer Megan Williams (WWDC25 session 272, "Read documents using the Vision framework"): *"This year, Vision is replacing our model for hand pose detection with a smaller, modernized model. The new model will still detect 21 joints, but with improved accuracy, less memory usage, and less latency... the joints are not in the same location as the previous model."* It's free, always present, and requires no third-party dependency.

2. **MediaPipe is more accurate on 3D landmarks and cross-platform, but is a worse fit for a shipping native Mac app.** Its Tasks/Python API is CPU-only in practice on macOS (GPU/Metal delegate benefits are inconsistent and there have been memory-leak reports), and embedding it natively requires wrestling with Bazel/C++ or shipping a Python runtime. Its Gesture Recognizer does ship canned gesture classes out of the box — per Google's official docs, the model bundle recognizes 7 labels: *"Closed_Fist, Open_Palm, Pointing_Up, Thumb_Down, Thumb_Up, Victory, ILoveYou"* (plus Unknown/None) — which is convenient for prototypes.

3. **For dynamic/temporal gestures Apple gives you Create ML hand-pose and hand-action classifiers**, but Apple explicitly notes the body Action Classifier is not designed for hands; for hand actions you train an ML Hand Action Classifier (temporal window of frames) or an ML Hand Pose Classifier (static). For a small command vocabulary, simple geometric heuristics on the landmarks are often enough and most reliable.

4. **Triggering is well-supported.** Ghostty launches via `NSWorkspace.shared.openApplication(at:configuration:)`. Superwhisper exposes official deep links — per Superwhisper's docs (superwhisper.com/docs/modes/switching-modes): *"You can use the following deep links with Superwhisper: `superwhisper://mode?key=YOUR_MODE_KEY` [and] `superwhisper://record`... Combine both deep links in automation tools to switch modes and start recording in one action."* Superwhisper also added dedicated start/stop-recording deep links and supports toggle/cancel-recording hotkeys. Arbitrary shortcuts are sent via `CGEvent` keyboard synthesis (needs Accessibility permission).

5. **Strong prior art exists to fork/study**, most notably the Swift/Vision project **Gstrl** (`TomYang-TZ/Gstrl`), which does exactly this: Apple Vision `VNDetectHumanHandPoseRequest` → gesture classifier → CGEvents, with pinch, swipe, finger-count and two-hand combos, plus a speech mode. Other references: `svrohith9/mac-camera-app` (Vision hand-pose SwiftUI Mac app), `rogino/VirtualBar` (Vision-based, with candid notes on Vision vs MediaPipe on Mac), and many Python MediaPipe→PyAutoGUI controllers.

## Details

### 1. Apple-native options (recommended core)

**`DetectHumanHandPoseRequest` / `VNDetectHumanHandPoseRequest`.** Returns a `HumanHandPoseObservation` with 21 landmarks per hand grouped by finger (TIP/DIP/PIP/MIP joints, thumb TIP/IP/MP, plus wrist). Each point carries a confidence you can threshold (e.g. ignore points below 0.3). You control `maximumHandCount` — set it to 1 or 2; higher counts cost performance. The modern Swift API (iOS 18/macOS 15+ and current in macOS 26) uses async/await: create the request, run an `ImageRequestHandler` over each `CMSampleBuffer`/`CVPixelBuffer` from the camera, read `observation.allJoints(in:)`.

**macOS Tahoe 26 status.** At WWDC25 Apple confirmed the improved model (quote above) and warned the joint locations differ slightly, so existing Create ML classifiers should be retrained. Importantly, **there is no publicly documented new `DetectHumanHandPoseRequest` revision number to explicitly opt into the 2025 model.** Apple Developer Forums thread #803595 ("Updated DetectHandPoseRequest revision from WWDC25 doesn't exist") reports only the existing revisions — Swift `revision1` (iOS 18+) and Obj-C `VNDetectHumanHandPoseRequestRevision1` (iOS 14+) — stating *"I don't see any new revision targeting iOS26+."* Treat the improved model as delivered through the OS on Tahoe 26; verify against the latest SDK when you build.

**Performance / Neural Engine.** Apple publishes no official hand-pose FPS/latency number, claiming only "lower latency, lower memory." Third-party measurements of the sibling body-pose request are the best proxy: Apple's Vision pose detector runs at 30+ FPS on the Mac Neural Engine, and single-frame Vision pose inference is roughly 8–12 ms on the Neural Engine (rising to 30–40 ms on CPU fallback). On an M5 Max with 128 GB RAM, real-time hand tracking at 30–60 FPS with headroom is entirely realistic; the practical bottleneck is your capture frame rate and how often you run the request, not compute. (Note: a naive SwiftUI/Vision tutorial reported only ~12.5 FPS and an older iPhone 7 sample ~5 FPS — those are throttled/old-hardware figures, not the ceiling on your Mac.)

**Static pose vs dynamic gesture.**
- *Static pose (recommended):* read landmarks each frame, apply geometric rules (finger extended/curled, thumb–index distance for pinch) or an ML Hand Pose Classifier. Lowest latency, most robust.
- *Dynamic/temporal:* ML Hand Action Classifier trained in Create ML over a rolling window of frames (predictions made window-by-window continuously). Needed for swipes/waves; more false positives, more tuning.

### 2. Cross-platform ML options (prototype / specialized)

- **MediaPipe Hands / Gesture Recognizer.** 21 3D landmarks (x, y, z in meters relative to hand center), handedness, and — with the Gesture Recognizer — the 7 built-in gesture classes above plus custom classes via Model Maker. Two-stage palm-detector + landmark model; in video/stream mode it tracks from the previous frame's box to skip the expensive palm detector. Per Google Research, the landmark model was trained on *"~30K real-world images"* plus rendered synthetic hands, and its BlazePalm palm detector achieves 95.7% average precision. **Occlusion caveat:** contrary to the common claim that MediaPipe is highly robust to occlusion, a 2025 AR hand-pose study (arXiv:2606.17427) found that *"while WiLoR, HaMeR, and WildHands could not generate a prediction on <1% of the accepted ground truth frames, MediaPipe could not generate a prediction on ~22% of the accepted ground truth frames"* — i.e. it drops out under hard occlusion far more than transformer models. On macOS the Python binding is effectively CPU-only and there are reports of high memory use and GPU/CPU parity issues; the C++/Tasks path gives GPU but is painful to build (Bazel). Great for a quick Python proof-of-concept; weak for a polished native Mac app.
- **OpenCV + MediaPipe (Python):** the standard hobbyist stack (`cv2.VideoCapture` → MediaPipe landmarks → PyAutoGUI). Fast to build, not battery- or latency-optimal, and not a clean native app.
- **YOLO-based hand detection:** good for bounding-box hand detection/counting but not 21-landmark precision on its own; overkill here.
- **WiLoR / HaMeR (2024–2025 SOTA 3D):** transformer-based full 3D hand mesh (MANO). Per the WiLoR paper (Potamias et al., arXiv:2409.12259), it is state-of-the-art on FreiHAND (PA-MPJPE 5.5 mm, PA-MPVPE 5.1 mm, F@5 = 0.825) and *"the hand detector... runs at 138 FPS for the medium model and 175 FPS for the small variant on an NVIDIA RTX 4090, while maintaining a compact 7MB model size"* — i.e. those speeds require a CUDA GPU, not the Mac Neural Engine. Research-grade and unnecessary (and hard to deploy on Mac) for a small command vocabulary.

### 3. Recommended architecture for your app

- **App shell:** SwiftUI + AppKit menu-bar (`MenuBarExtra`/`NSStatusItem`) background app. Keep it always-running and lightweight.
- **Capture:** `AVCaptureSession` with `AVCaptureVideoDataOutput`, delegate on a dedicated dispatch queue. To save battery, **downsample and throttle**: request a modest resolution (e.g. 640×480 or 1280×720), and do not run Vision on every frame — cap inference to ~15–20 Hz via a minimum inter-inference interval (a common tutorial value is ~0.08 s ≈ 12.5 FPS). Set the capture device's min/max frame duration to limit FPS at the source.
- **Detection:** one `DetectHumanHandPoseRequest`, `maximumHandCount = 1` (or 2 for combos). Discard low-confidence joints.
- **Gesture classifier:** start with geometric heuristics (finger extended if TIP is farther from wrist than PIP; pinch if normalized thumb-tip↔index-tip distance < threshold). Graduate to a Create ML Hand Pose Classifier if you need many poses.
- **Debounce / smoothing:** require the same pose for N consecutive frames (e.g. 3) before firing; add a post-fire cooldown (e.g. 800 ms–1 s) so one gesture = one action; use confidence hysteresis (higher threshold to enter a state than to stay). This is the single biggest lever on false-positive rate.
- **Mapping layer:** a user-editable dictionary of gesture → action. Keep it data-driven so you can add gestures without recompiling.

### 4. Triggering macOS actions

- **Launch Ghostty:** resolve its bundle identifier and call `NSWorkspace.shared.openApplication(at: url, configuration:)` (the modern replacement for deprecated `launchApplication`). If sandboxed you may hit launch-permission issues — a non-sandboxed helper is simplest for a personal power-tool. Alternatively shell out to `/usr/bin/open -a Ghostty`.
- **Control Superwhisper:** open `superwhisper://record` to start/stop recording and `superwhisper://mode?key=YOUR_MODE_KEY` to switch modes (combine them to switch-and-record in one action). Superwhisper also added dedicated start/stop-recording deep links and supports toggle/cancel-recording hotkeys, so a gesture can either fire the deep link or synthesize its configured hotkey.
- **Arbitrary shortcuts / keystrokes:** synthesize with `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, set `.flags` for modifiers, `post(tap: .cghidEventTap)`. This is how you drive any app that only exposes a hotkey.
- **Shortcuts app:** you can also run a named Shortcut via `shortcuts run "Name"` (URL scheme or CLI) for complex chains without writing more Swift.
- **Permissions required:** Camera (`NSCameraUsageDescription`), Accessibility (for `CGEvent` posting / global control), and Screen Recording only if you capture the screen (e.g. for a screenshot gesture). Prompt via `AXIsProcessTrustedWithOptions`.

### 5. Existing open-source projects to learn from or fork

- **`TomYang-TZ/Gstrl`** (github.com/TomYang-TZ/Gstrl) — the closest match to your goal. Native Swift, MIT-licensed. Uses Apple Vision `VNDetectHumanHandPoseRequest` for landmarks + a gesture classifier (pinch via palm-center tracking, velocity-based swipes requiring an open hand, two-hand combos, left-hand-wrist-Y as a scroll joystick), turning poses into `CGEvents`. Adds `SFSpeechRecognizer` speech mode. Runs fully on-device; targets 60 FPS (configurable to 120), macOS 14+. Maps e.g. quick pinch→click, hold 1–3 fingers→type digits, fist→Enter, swipes→arrow keys, both fists→AI agent. Self-reported (no independent benchmarks), small/early repo (~3 stars, no releases), but an ideal architecture reference.
- **`svrohith9/mac-camera-app`** — minimal SwiftUI macOS app: live camera + Vision hand-pose finger-painting; clean example of the AVFoundation + Vision + camera-permission plumbing (includes `NSCameraUsageDescription`, a `build.sh` that links SwiftUI/AVFoundation/Vision into a `.app`).
- **`rogino/VirtualBar`** — Vision-framework Mac gesture project whose README candidly notes Vision "doesn't work great" for partial hands while *"MediaPipe hands is better, but I could barely get it compiling... on macOS"* — a useful honest datapoint on the Vision-vs-MediaPipe tradeoff on Mac.
- **Python/MediaPipe controllers** (`david-0609/OpenCV-Hand-Gesture-Control`, `SrishtiS-git/Hand-Gesture-Mouse-Scroll-Controller`, `baukk/Gesture-Recognition`, `fikriaf/HandCam-Control`) — good for gesture-logic ideas (finger-up counting, swipe velocity, debounce/smoothing config like `velocityThreshold`/`smoothingWindow`/`debounceMs`) even though they're not native Mac apps. Several authors explicitly warn accuracy suffers with imprecise landmarks and poor lighting.

### 6. Precision / effectiveness comparison

| Option | Landmarks | Accuracy (small vocab) | Latency on M5 Max | False-positive control | Native Mac fit | Verdict |
|---|---|---|---|---|---|---|
| **Apple Vision hand pose** | 21 (2D) | High for static poses | Very low (ANE, single-digit–low-double-digit ms; 30–60 FPS) | Excellent (you own thresholds) | Native, zero deps | **Best overall** |
| MediaPipe Hands/Gesture Recognizer | 21 (true 3D) | High; 7 canned gestures; but ~22% dropout under hard occlusion | Good but CPU-bound on Mac Python | Good | Poor (Bazel/Python) | Prototype / 3D needs |
| Create ML Hand Pose/Action Classifier | uses Vision's 21 | High; enables temporal gestures | Low (Core ML on ANE) | Excellent | Native | Add-on for dynamic gestures |
| WiLoR / HaMeR | full 3D mesh | SOTA 3D (PA-MPJPE ~5.5 mm) | Needs CUDA GPU; not Mac-friendly | n/a | Poor | Overkill |
| OpenCV heuristics only | none/contours | Low/brittle | Low | Poor | n/a | Avoid |

**Most reliably distinguished gestures:** open palm, closed fist, thumbs-up, "peace"/victory (two fingers), pointing (one finger), and pinch (thumb–index contact), plus discrete finger-counts 1–5. These differ sharply in landmark geometry and are robust to lighting/orientation. Avoid relying on subtle differences (e.g. ring vs middle finger extended alone), fast motion gestures, and two-hand combos for your *primary* triggers — keep those for secondary/confirm actions.

## Recommendations

**Stage 1 — Prototype the logic (1–2 days).** If you want to validate gesture ideas fast, throw together a Python MediaPipe + OpenCV script and print recognized gestures. Its 7 built-in gesture labels cover most of what you'll want. Use this only to nail down *which* gestures feel natural and how to threshold them — don't ship it.

**Stage 2 — Build the real app (recommended stack).**
1. SwiftUI menu-bar app (`MenuBarExtra`), non-sandboxed for a personal tool.
2. `AVCaptureSession` at 640×480–720p, inference throttled to ~15 Hz, `maximumHandCount = 1`.
3. `DetectHumanHandPoseRequest` → geometric pose classifier (start with pinch, open palm, fist, victory, 1–5 count).
4. Debounce = 3 consecutive frames + confidence ≥ ~0.6 + 800 ms cooldown per action.
5. Data-driven gesture→action map. Wire: open-palm→launch Ghostty (`NSWorkspace.openApplication`); fist→toggle Superwhisper (`superwhisper://record`); victory→a `CGEvent` hotkey; etc.
6. Request Camera + Accessibility permissions on first run (`AXIsProcessTrustedWithOptions`).

**Stage 3 — Harden.** Add temporal gestures only if needed (Create ML Hand Action Classifier, retrained on the Tahoe 26 model). Add a visible menu-bar state indicator and an easy "pause detection" toggle. Add a "hand must be held steady" gate to kill accidental triggers.

**Benchmarks / thresholds that would change the plan:**
- If you need **true 3D finger depth** (e.g. distinguishing hand tilt/rotation precisely) → add MediaPipe (accept the Python/C++ integration cost) or evaluate WiLoR offline.
- If Vision's new Tahoe model mislocates joints for your poses → retrain a Create ML Hand Pose Classifier on your own captures.
- If CPU/battery is high → lower inference Hz first (biggest win), then resolution; confirm the request is landing on the Neural Engine, not CPU fallback.
- If false positives persist → raise consecutive-frame count and cooldown before adding more gestures.

## Caveats
- **No official Apple hand-pose latency/FPS figure exists.** The single-digit-ms and 30–60 FPS numbers here are extrapolated from third-party *body-pose* measurements and Apple's qualitative "lower latency" claim for the Tahoe 26 model; benchmark your own pipeline. Some tutorials report only ~5–12.5 FPS because they deliberately throttle or ran on old hardware — not representative of an M5 Max.
- **The macOS 26 hand-pose model change is confirmed by Apple (WWDC25), but the opt-in mechanism is not.** No new `DetectHumanHandPoseRequest` revision was publicly documented as of late 2025 (per forum thread #803595); the model appears delivered via the OS. Verify in the current Xcode/SDK, and retrain any Create ML classifiers because joint locations shifted.
- **MediaPipe-on-Mac claims are mixed:** GitHub issues report both CPU/GPU parity problems and heavy memory use, and it drops ~22% of frames under hard occlusion; treat its "GPU acceleration on Mac" and "occlusion robustness" as unreliable.
- **Gstrl and similar repos are self-reported and early-stage.** Use them as architecture references, not as validated performance sources.
- **Superwhisper deep links** (`superwhisper://record`, `superwhisper://mode?key=`) are documented and current as of 2026, but URL schemes can change between versions — confirm against the installed app and consider the hotkey path as a fallback.
- **Front-camera mirroring:** the built-in webcam feed is mirrored; account for handedness/orientation so "left" and "right" gestures map correctly.
- **Sandboxing/App Store:** `CGEvent` posting and launching arbitrary apps are awkward under the App Sandbox; a non-sandboxed personal build is far simpler. Distribution via the Mac App Store would require rework.