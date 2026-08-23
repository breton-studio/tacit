# Top 20 Ergonomic Hand Gestures for Webcam-Based macOS Shortcut Control: An Evidence-Based Design Guide

## TL;DR
- **The single most important finding:** For a laptop-webcam gesture system, the highest-frequency shortcuts should be mapped to **small, static thumb-to-finger microgestures and single-finger poses performed with the forearm resting on the desk** — the resting arm eliminates the "gorilla-arm" shoulder fatigue quantified by Hincapié-Ramos et al.'s Consumed Endurance metric (CHI 2014), while neutral-wrist, concordant-finger poses avoid the discomfort factors identified by Rempel, Camilleri & Lee (2014) in sign-language interpreters.
- **Static poses are lower-effort but higher false-positive risk; dynamic gestures are more fatiguing but far more distinguishable** from resting/typing hands — so the practical answer is a hybrid: a small static "clutch/wake" gesture to arm the system (defeating the Midas-touch problem), followed by static poses for high-frequency commands and short dynamic swipes for occasional/directional commands.
- **Detectability on a standard RGB webcam via MediaPipe Hands is reliable (~90%+) for open, un-occluded, palm-facing poses in good light but degrades sharply with self-occlusion, edge-of-frame hands, and low light** — so gestures must be chosen for landmark visibility, not just comfort.

## Key Findings

1. **Resting the arm is the biggest ergonomic lever.** Consumed Endurance (Hincapié-Ramos et al., CHI 2014) shows shoulder fatigue in mid-air interaction follows Rohmert's endurance-time model, which is asymptotic at ~15% of maximum voluntary shoulder force — forces below that can be sustained almost indefinitely. Raised-arm "free-air" gestures exceed this; a forearm resting on the desk removes the shoulder torque almost entirely. Therefore the desk-resting context is strongly preferred for anything used more than a few times per hour.

2. **The most comfortable hand postures are known and specific.** Rempel, Camilleri & Lee (2014), rating 33 postures with 24 professional sign-language interpreters, found high discomfort was statistically associated with **a flexed wrist, discordant adjacent fingers, or extended/spread fingers**, while comfortable gestures have **the wrist straight/neutral and adjacent fingers similarly shaped** (concordant), e.g., a loose fist, slightly-flexed fingers, loose pointing, thumbs-up. They explicitly recommend assigning the most comfortable gestures to the most frequent commands.

3. **Microgestures (thumb-to-finger) are the research-favored low-fatigue primitive.** Meta and Ultraleap production guidelines and Chan et al. (CHI 2016) converge: small thumb taps/swipes on the index finger from a relaxed hand are low-effort, socially subtle, and map naturally onto touchscreen idioms. The thumb was involved in 88% of elicited single-hand microgestures (Chan et al. 2016, analysis of 1,632 gestures from 16 participants).

4. **Static vs dynamic is a real trade-off.** Static poses require lower effort and less motion but are easily triggered accidentally (Midas touch). Dynamic gestures (swipes, rotations) cost more motion/fatigue but are much less likely to occur incidentally while typing or conversing, and state-machine detection (e.g., fist→open = swipe) is both robust and cheaper computationally.

5. **A clutch/activation mechanism is essential.** The Midas-touch problem — incidental movements being read as commands — is the central reliability failure mode. The literature's answer is a clutch: a deliberate wake pose/gesture unlikely to occur incidentally (fist, pinch-and-hold, "teapot" pose), optionally with a short dwell.

6. **Detectability constrains the menu.** MediaPipe Hands localizes 21 landmarks and is robust to partial occlusion and self-occlusion down to a point, but recall roughly halves at high occlusion levels, and RGB recognition accuracy collapses in low light (one study: 95.5% normal light → 46.2% low light → 33.3% dark). Poses that keep the palm toward the camera and fingers separated are the most reliable.

## Details

### A. The evidence base

**Fatigue and the gorilla arm.** Hincapié-Ramos, Guo, Moghadasian & Irani, "Consumed Endurance: A Metric to Quantify Arm Fatigue of Mid-Air Interactions," CHI 2014 (pp. 1063–1072), derived a shoulder-torque-based metric built on Rohmert's endurance-time model and validated against the Borg CR10 scale: "Linear correlation between Borg CR10 and CE show a strong correlation (R = 0.846) where CE predicts 72% of the variability in Borg CR10 ratings (R² = 0.716)." Key design results: users consumed least endurance when the **arm was bent and operating midway between shoulder and waist**, and CE is gender-neutral. Rohmert's endurance curve is asymptotic at 15% of maximum force — the biomechanical justification for keeping muscular load low and for resting the arm. Follow-on models (Jang et al., Cumulative Fatigue, CHI 2017; NICER, ACM TOG 2024) add recovery dynamics but confirm CE's framing. Subjective instruments used across this literature: NASA-TLX (Hart & Staveland 1988) and Borg CR10/RPE (Borg).

**Posture comfort.** Rempel, Camilleri & Lee, "The design of hand gestures for human–computer interaction: Lessons from sign language interpreters," Int. J. Human-Computer Studies 72 (2014), 728–735. N=24 professional interpreters; 47 characters/words + 33 postures rated on a comfortable(−1)/neutral(0)/uncomfortable(+1) scale; postures coded across 6 joint dimensions into 64 classes; nominal logistic regression. **High discomfort ⇐ flexed wrist, discordant adjacent fingers, extended fingers.** Uncomfortable arm postures: elbows flexed, forearms rotated (full pronation/supination), shoulders externally rotated. Thumb position had little influence. Comfortable exemplars from their Fig. 5 (verbatim caption): "(1c) fingers slightly flexed; (2c) hand in a loose fist; (5c) loose hand pointing; (6c) thumb up," plus forearm neutral-to-45°-pronation. Uncomfortable exemplars: "halt" sign (wrist+fingers extended), ulnar-deviated wrist with extended fingers, shaka sign (discordant fingers), fingers extended and abducted. Explicit recommendation: **use comfortable gestures for frequent tasks; reserve slightly less comfortable ones for infrequent tasks; avoid prayer/halt gestures for common tasks.** Context on repetitive-gesturing risk: occupational-health surveys of interpreters report high symptom prevalence — Feuerstein et al. (1997) found 69.6% reporting hand/wrist symptoms, and NIOSH-linked studies place work-related upper-extremity MSD prevalence roughly in the 16–32% range depending on site — a warning about sustained gesturing load.

**Elicitation / guessability.** Wobbrock, Morris & Wilson, "User-Defined Gestures for Surface Computing," CHI 2009 (1,080 gestures, 20 participants, 27 commands): users prefer **one hand over two**, rarely care about number of fingers, are heavily influenced by desktop idioms (legacy bias), and **complex/abstract referents (e.g., copy/paste, app-switch) elicit low agreement** — meaning these have no "natural" gesture and are better served by an arbitrary-but-learnable mapping. The 216-study systematic review (Villarreal-Narvaez, Vanderdonckt, Vatavu & Wobbrock, DIS 2020) generalizes these methods. For toggles (on/off, play/pause), Chan et al. recommend identical gestures for both states.

**Microgestures & subtle interaction.** Chan, Seyed, Stuerzlinger, Yang & Maurer, "User Elicitation on Single-Hand Microgestures," CHI 2016: thumb involved in 88% of gestures; **all swipes performed with the thumb**; taps most common (19/34 referents, favored for precision/selection), swipes second (14/34, favored for continuous/dichotomous ranges like volume/zoom). **Ring finger least feasible** (tendon coupling via connexus intertendineus with the middle finger); **pinky seldom used** (2/34; reduced strength, discomfort). Meta Horizon and Ultraleap production guidance: relaxed sideways hand, thumb resting on the side of the index finger, discrete thumb taps/swipes = "low-calorie," low-strain, occlusion-friendly input; keep the active gesture set small to avoid overload.

**Biomechanics/RSI.** Hand-clinic biomechanics: PIP joint has the largest dynamic range of motion and highest peak velocity; MCP ≈ 0/90° flexion, PIP ≈ 0/100°, DIP ≈ 0/60–80°, thumb IP ≈ 0/80°. During pinch, MCP:PIP:DIP share flexion roughly 59:32:9. Pinch-tip forces are amplified 10–13× at the thumb basal (CMC) joint — so **sustained forceful pinch is a genuine CMC/tendon risk**, though a large field EMG study (Pinch Grip per SE…, 2022) found *low-force* pinch alone is not an occupational risk factor. RSI drivers per NIOSH-derived ergonomics literature: number of force exertions per day and awkward joint position; sustained gripping/pinching linked to stenosing tenosynovitis (trigger finger) and De Quervain's ("gamer's thumb"). Practical implication: **for gestures, keep any pinch brief and near-zero force (a light touch, not a squeeze), keep the wrist neutral, and ensure fast recovery to a relaxed rest posture.**

**Social acceptability.** Rico & Brewster (CHI 2010) established that willingness to perform a gesture depends on location and audience, and that **subtle/secretive gestures outperform large "suspenseful" ones** in public. Small desk microgestures score well here; large free-air waving does not.

### B. Context buckets

**(a) Desk-resting / micro-gesture context (arms on desk or lap, low amplitude).**
- Pros: near-zero shoulder load (Consumed Endurance ≈ 0 with forearm supported); sustainable for high-frequency use; socially subtle; hand stays near keyboard so recovery to typing is instant; forearm support substantially reduces shoulder muscle tension (established ergonomics practice for mouse-intensive work).
- Cons: hand often at a shallow/oblique angle to a laptop webcam mounted at screen-top, worsening self-occlusion of curled fingers; small movements are harder to distinguish from natural micro-movements/typing; requires the hand to be lifted slightly into the camera's field of view or the webcam angled down.

**(b) Free-air context (arm raised in front of camera).**
- Pros: excellent landmark visibility (palm can face camera, fingers separated, whole hand in frame); large motions are unambiguous and low false-positive; good for occasional, deliberate commands.
- Cons: gorilla-arm fatigue rises steeply with time held above ~15% max shoulder force (CE/Borg); poor for high-frequency use; low social acceptability; slower to initiate and recover from.

### C. Frequency tiers

**High-frequency (dozens/hour: copy, paste, app-switch, tab-switch, undo).** Ergonomic bar is highest: minimal joint excursion, neutral wrist, low muscular load, instant recovery. Best served by **static desk-resting microgestures and single-finger poses**, gated behind a clutch. Note Wobbrock's finding that these abstract commands have no intuitive gesture — so pick the *most comfortable/detectable* gestures and rely on learnability, not guessability.

**Occasional (media play/pause, volume, window management, screenshots).** Tolerates more motion and amplitude. Best served by **dynamic swipes, rotations, and slightly larger poses**, which buy false-positive robustness at an acceptable fatigue cost given low repetition. Rempel's rule: slightly-less-comfortable gestures are acceptable here.

### D. Static vs dynamic — category pros/cons

| | Static poses | Dynamic gestures |
|---|---|---|
| Effort/fatigue | Low (single settling motion) | Higher (sustained motion path) |
| False-positive risk | **Higher** (a resting/typing hand can resemble a pose) | **Lower** (motion signature rare incidentally) |
| Detection cost | Low (single-frame classification) | Higher (temporal state machine) |
| Recovery to rest | Instant | Slightly slower |
| Best tier | High-frequency | Occasional/directional |

A robust production pattern combines them: static clutch → static command, or fist→open-hand modeled as a swipe (state-based; a Huawei/USPTO patent method notes state-based recognition is "less prone to false positives" than motion segmentation).

### E. Detectability notes (MediaPipe Hands / Apple Vision on laptop webcam)
- MediaPipe returns 21 3D landmarks; built-in canned gestures are Closed_Fist, Open_Palm, Pointing_Up, Thumb_Down, Thumb_Up, Victory, ILoveYou — these are the "free" reliable primitives.
- Reported real-world accuracy on RGB webcams: Kumar et al., IJRASET (March 2026), "Real-Time Hand Gesture Recognition for Markerless Virtual Mouse Control Using MediaPipe Landmarks," report cursor movement ≈95%, left click ≈92%, right click ≈90%, scroll ≈88%, at 25–40 FPS on standard laptops.
- Occlusion: robustness holds for partial/self-occlusion but recall roughly halves at high occlusion; poses where fingers hide behind the palm or each other (e.g., counting 3 with a folded thumb) are less reliable than palm-forward, separated-finger poses.
- Lighting: RGB accuracy drops sharply in low light — Machines 13(8):701 (2025) reports RGB accuracy 95.5% (normal) → 46.2% (low light) → 33.3% (dark). Distance: near-perfect ≤2 m, degrading by ~3–4.5 m.
- Camera angle: laptop webcams sit high and look slightly down; hands resting flat on the desk are seen edge-on, hurting curled-finger poses — favor poses read from the back/side of the hand or lift the hand slightly.

## The Top 20 Gestures

**Bucket 1 — Static, desk-resting, high-frequency (the workhorses).**

1. **Thumb-to-index tap (light pinch-touch, released immediately).** Static (brief). Desk. High-freq. Rationale: lowest-excursion discrete action; thumb opposition is natural (88% of elicited microgestures used the thumb); near-zero force keeps CMC load safe. RSI: safe if brief and light — avoid *sustained/forceful* pinch (10–13× force amplification at CMC). Detectability: pinch (thumb–index distance) is the single most reliable microgesture on MediaPipe. False-positive: moderate — gate behind clutch. Map: **primary "click"/select or Copy (⌘C).**
2. **Thumb-to-middle tap.** Static. Desk. High-freq. Rationale: distinct second discrete channel; middle finger is second-most independent. Detectability: good. FP: moderate. Map: **Paste (⌘V).**
3. **Index-finger point (single finger up, others curled).** Static. Desk/free-air. High-freq. Rationale: comfortable (loose pointing rated comfortable by Rempel); MediaPipe Pointing_Up is a canned class. FP: low-moderate. Map: **cursor-move mode / activate.**
4. **Two-finger "Victory"/peace (index+middle up, separated).** Static. Desk/free-air. High-freq. Rationale: canned MediaPipe class, highly separable landmarks. Caveat: Rempel flags discordant/spread fingers as less comfortable — acceptable at brief high-freq use but not to be *held*. FP: low. Map: **switch tab (⌃Tab / ⌘{ }).**
5. **Thumbs-up.** Static. Desk/free-air. High-freq/occasional. Rationale: comfortable (Rempel Fig. 5), canned class, very separable. FP: low but occurs socially — gate. Map: **confirm/Enter or "yes".**
6. **Closed fist (loose).** Static. Desk. High-freq/clutch. Rationale: loose fist rated comfortable; excellent as a **clutch/wake** and as a state anchor for swipes. Detectability: MediaPipe Closed_Fist canned class, palm-detector trained on fists → very robust. FP: low. Map: **clutch/activation (hold to arm system) or app-switch (⌘Tab).**
7. **Open palm (fingers relaxed, facing camera).** Static. Desk/free-air. High-freq/clutch. Rationale: max landmark visibility, canned class. Caveat: fully extended+abducted fingers are less comfortable — keep relaxed, not splayed. FP: low. Map: **stop/deactivate clutch or Mission Control.**
8. **Thumb-to-ring or thumb-to-pinky tap.** Static. Desk. Occasional (not high-freq). Rationale: adds channels but ring finger is least feasible (tendon coupling) and pinky is weak — reserve for rarer commands. Detectability: moderate (fingers may occlude). Map: **screenshot (⌘⇧4) / rarer command.**

**Bucket 2 — Dynamic, desk or near-field, occasional/directional.**

9. **Thumb swipe along index side — forward/back.** Dynamic (micro). Desk. High-freq-capable. Rationale: Ultraleap/Meta's core microgesture; low fatigue, resembles scroll/D-pad. FP: low (motion signature). Map: **tab next/previous or undo/redo.**
10. **Horizontal hand swipe left.** Dynamic. Desk/free-air. Occasional. Rationale: directional, unambiguous; low FP. Fatigue: modest. Map: **back / previous desktop (⌃←).**
11. **Horizontal hand swipe right.** Dynamic. Occasional. Map: **forward / next desktop (⌃→).**
12. **Swipe up (flick).** Dynamic. Occasional. Map: **Mission Control (⌃↑).**
13. **Swipe down (flick).** Dynamic. Occasional. Map: **App Exposé / minimize (⌃↓).**
14. **Fist → open-hand "release."** Dynamic (state-based). Desk. Occasional. Rationale: two robust static states chained → very low FP (state-machine method). Map: **close window (⌘W) / clear.**
15. **Pinch-and-drag (hold light pinch, translate hand).** Dynamic. Desk. Occasional. Rationale: continuous control with a clear start/stop clutch (pinch = engaged). Keep force near zero. Map: **volume/brightness scrub or window drag.**
16. **Wrist rotation (pronate/supinate) with loose fist ("knob").** Dynamic. Desk/free-air. Occasional. Rationale: rotary metaphor for continuous values. Caveat: full pronation/supination is uncomfortable (Rempel) — use only a partial arc. Map: **volume / zoom.**
17. **Two-finger vertical swipe (index+middle).** Dynamic. Desk. Occasional. Rationale: scroll metaphor, separable. Map: **scroll / zoom in-out.**

**Bucket 3 — Free-air, occasional, deliberate (lowest-frequency, highest-visibility).**

18. **Open-palm push toward camera (Z-axis).** Dynamic. Free-air. Occasional. Rationale: deliberate, unambiguous, but coarse Z on mono RGB — use as a big confirm. Fatigue: raised arm, so keep rare. Map: **play/pause or send/Enter.**
19. **Hand wave.** Dynamic. Free-air. Occasional/rare. Rationale: highly separable, socially legible; high FP if in conversation, so rare-only. Map: **dismiss notification / lock screen.**
20. **Two-handed "frame"/both-fists.** Dynamic/static. Free-air. Rare. Rationale: two-handed gestures are deliberate and near-impossible to trigger accidentally (very low FP) but violate Wobbrock's one-hand preference and are fatiguing — reserve for a powerful rare action. Map: **screenshot region (⌘⇧4) / invoke AI assistant.**

### Summary table

| # | Gesture | Static/Dynamic | Context | Freq tier | Fatigue/RSI | Detectability | FP risk | Example macOS map |
|---|---|---|---|---|---|---|---|---|
|1|Thumb–index tap|Static(brief)|Desk|High|Low (brief/light)|High|Med|Copy ⌘C / click|
|2|Thumb–middle tap|Static|Desk|High|Low|High|Med|Paste ⌘V|
|3|Index point|Static|Desk/air|High|Low|High|Low-Med|Cursor/activate|
|4|Victory (2-finger)|Static|Desk/air|High|Low (brief)|High|Low|Switch tab|
|5|Thumbs-up|Static|Desk/air|High/Occ|Low|High|Low(social)|Confirm/Enter|
|6|Loose fist|Static|Desk|Clutch/High|Low|Very high|Low|Clutch / ⌘Tab|
|7|Open palm|Static|Desk/air|Clutch/High|Low|Very high|Low|Stop / Mission Control|
|8|Thumb–ring/pinky tap|Static|Desk|Occasional|Med (weak fingers)|Med|Med|Screenshot|
|9|Thumb swipe on index|Dynamic(micro)|Desk|High|Low|High|Low|Tab next/prev, undo|
|10|Swipe left|Dynamic|Desk/air|Occ|Low-Med|High|Low|Back ⌃←|
|11|Swipe right|Dynamic|Desk/air|Occ|Low-Med|High|Low|Forward ⌃→|
|12|Swipe up|Dynamic|Desk/air|Occ|Med|High|Low|Mission Control ⌃↑|
|13|Swipe down|Dynamic|Desk/air|Occ|Med|High|Low|App Exposé ⌃↓|
|14|Fist→open|Dynamic(state)|Desk|Occ|Low|Very high|Very low|Close window ⌘W|
|15|Pinch-drag|Dynamic|Desk|Occ|Low (light)|High|Low|Volume scrub / drag|
|16|Wrist rotate knob|Dynamic|Desk/air|Occ|Med (limit arc)|Med|Low|Volume/zoom|
|17|Two-finger vscroll|Dynamic|Desk|Occ|Low|High|Low|Scroll/zoom|
|18|Palm push (Z)|Dynamic|Free-air|Occ|Med (raised)|Med (coarse Z)|Low|Play/Pause|
|19|Wave|Dynamic|Free-air|Rare|Med|High|Med(social)|Dismiss/lock|
|20|Two-hand frame/fists|Two-hand|Free-air|Rare|High|High|Very low|Screenshot region / AI|

### Design principles distilled from the literature
1. **Rest the arm.** Keep the forearm supported; keep any raised-arm gesture rare and brief (Consumed Endurance / Rohmert 15% rule).
2. **Neutral wrist, concordant fingers.** Avoid wrist flexion/deviation and spread/extended-finger poses for anything repeated (Rempel et al. 2014).
3. **Near-zero force.** Pinches are touches, not squeezes (CMC 10–13× force amplification; trigger-finger/De Quervain risk).
4. **Fast recovery to rest.** High-frequency gestures must return instantly to a relaxed posture near the keyboard.
5. **Clutch to defeat Midas touch.** Require a deliberate wake pose (fist/pinch-hold) ± short dwell before commands register.
6. **Exploit motion for robustness.** Use dynamic/state-based gestures where accidental activation is costly.
7. **One hand preferred; reserve two-handed for rare, powerful, deliberate actions** (Wobbrock 2009).
8. **Symmetric/paired mappings** for opposite actions (swipe left/right, thumb swipe fwd/back); identical gesture for toggles (Chan 2016).
9. **Design for the camera:** palm-forward, fingers separated, hand within frame and well-lit; prefer MediaPipe's canned classes for reliability.
10. **Keep the active vocabulary small** to reduce cognitive load and inter-gesture confusion (Ultraleap).

### Anti-recommendations (intuitive but ergonomically poor or detection-unreliable)
- **Sustained/forceful pinch held as a mode** — CMC-joint stress and fatigue; use momentary taps or a hold with near-zero force instead.
- **"Halt"/prayer/flat-splayed-open-hand held** for frequent commands — extended+abducted fingers are among the least comfortable (Rempel).
- **Ulnar/radial-deviated wrist poses** — high discomfort, RSI-linked.
- **Finger-counting 3/4 with folded thumb** — self-occlusion lowers MediaPipe reliability and thumb-under is uncomfortable.
- **Ring-finger-isolated gestures** — anatomically coupled to the middle finger (least feasible per Chan 2016).
- **Held free-air poses for high-frequency use** — gorilla arm.
- **Relying on Z-axis push/pull for precision** — coarse and noisy on a single RGB webcam.
- **Bare static poses with no clutch** for destructive commands — Midas-touch false positives.

## Recommendations

| Stage | Action | Est. duration | Threshold to advance/change |
|---|---|---|---|
| 1. Baseline | Implement MediaPipe Hands + its 7 canned poses (fist, open palm, point, victory, thumbs-up, etc.); build a **fist-hold or pinch-hold clutch** with ~300–500 ms dwell | 3–5 days | Clutch false-activation rate < 1/hour in normal desk use |
| 2. High-freq core | Map gestures 1–7 (+9) to copy/paste/tab/app-switch behind the clutch; tune pinch as light-touch (distance threshold), not squeeze | 3–4 days | Per-gesture recognition ≥ 90%; user can sustain 30 min with Borg CR10 ≤ 2 |
| 3. Occasional layer | Add dynamic swipes (10–14), pinch-drag (15), rotation knob (16) with state-machine detection | 4–6 days | Dynamic-gesture FP during typing/conversation < 1/hour |
| 4. Ergonomic validation | Run a small study: NASA-TLX + Borg CR10 over a 1-hour session; log per-gesture accuracy, FP rate, and recovery time; instrument Consumed-Endurance-style arm-elevation logging | 1–2 weeks | If any high-freq gesture yields Borg > 3 or accuracy < 90%, demote it to occasional or replace |
| 5. Robustness hardening | Add lighting check + "hand out of frame" feedback; add per-user calibration and confidence thresholds (min_tracking_confidence ≈ 0.75) | 3–5 days | Accuracy in dim light either recovered > 85% or system prompts user to improve lighting |
| 6. Free-air/rare tier | Add gestures 18–20 for rare/deliberate actions only | 2–3 days | These stay < a few uses/hour by design |

**Immediate priorities:** (1) ship the clutch first — nothing else works reliably without it; (2) lead with fist/open-palm/point/thumbs-up (MediaPipe canned + Rempel-comfortable + high detectability); (3) treat any pinch as a light momentary touch; (4) validate with Borg CR10 and NASA-TLX before expanding the vocabulary.

## Caveats
- **Fatigue metrics were developed for the shoulder/mid-air**, not fingers. Consumed Endurance quantifies gorilla-arm; it does **not** capture intrinsic-hand-muscle or tendon fatigue from repeated finger microgestures — the finger-load evidence here comes from RSI/biomechanics and the Rempel interpreter study, which is about sign-language load, not webcam gestures specifically.
- **Rempel's exact per-gesture numeric discomfort scores (their Table 3) were not retrievable** from open sources; the direction of effects (flexed wrist, discordant/extended fingers = discomfort) is well established, but I could not verify per-character means.
- **Detectability figures come largely from individual implementation papers** (virtual-mouse studies, occlusion metamorphic-testing paper, a thermal-vs-RGB robot study) rather than a single standardized benchmark; real-world numbers depend heavily on webcam quality, angle, and lighting.
- **macOS shortcut mappings are illustrative suggestions**, not usability-tested pairings — Wobbrock's low-agreement finding for abstract commands means users will need to learn them regardless.
- Some cited items are **preprints or non-peer-reviewed** (arXiv, vendor docs, student-journal MediaPipe papers) — treated as engineering evidence, not clinical fact.
- The gesture list is a **synthesis/design recommendation**; no single published study ranks exactly these 20 for this exact laptop-webcam use case.