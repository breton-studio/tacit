import AppKit
import ApplicationServices
import Combine
import CoreVideo
import Foundation
import TacitCore

/// `CVPixelBuffer` isn't marked `Sendable` in this SDK, so Swift 6's region-based sendability
/// checker (correctly, in general) refuses to let a buffer produced on the capture queue be
/// handed across the `AsyncStream` continuation and on into `PipelineCore`'s actor-isolated
/// `process(...)` without proof nothing else retains/mutates it concurrently. In practice a single
/// pixel buffer here is handed off exactly once per frame and never touched concurrently —
/// `CaptureEngine.onFrame` is already declared `@Sendable (CVPixelBuffer, TimeInterval) -> Void` on
/// that same basis. This conformance makes that assumption explicit (the `@unchecked` the compiler
/// can't verify itself) rather than fighting the checker with awkward buffer copies.
extension CVPixelBuffer: @retroactive @unchecked Sendable {}

/// Owns the full capture → detection → classification → arbitration pipeline and publishes the
/// derived UI state (`EngineUIState`) that drives the menu bar glyph and popover.
///
/// ## Concurrency design
///
/// `CaptureEngine.onFrame` fires on the capture queue at ~15 Hz. Every frame is pushed into an
/// `AsyncStream<(CVPixelBuffer, TimeInterval)>` via its continuation (a plain, thread-safe,
/// `Sendable` value — no actor hop needed just to enqueue). Exactly one `Task`, created here in
/// `start()` (and so isolated to the main actor by inherited context, matching the rest of this
/// file's `Task { @MainActor in ... }` convention), consumes that stream with `for await`.
///
/// For each element it calls into `PipelineCore`, a plain (non-`@MainActor`) `actor` that owns the
/// `HandPoseDetector`, `StaticPoseClassifier`, and `ArbitrationEngine`. Awaiting an actor-isolated
/// method from the main actor hops execution onto the actor's *own* executor — never the main
/// thread — for the duration of that call, which is exactly what `HandPoseDetector`'s doc comment
/// warns is required (its `.perform()` call is synchronous Vision inference; it must never run on
/// the main actor). Because the consuming loop always `await`s one `process(...)` call to
/// completion before starting the next, calls into `PipelineCore` — and therefore into the
/// non-thread-safe `ArbitrationEngine` it owns — are never concurrent: `ArbitrationEngine` is
/// touched from exactly one logical, strictly-serialized caller, satisfying its "confine to one
/// executor" requirement without any locking. `PipelineCore` being an `actor` (rather than a class)
/// also means it's automatically `Sendable`, so no `@unchecked Sendable` escape hatch is needed to
/// pass a reference to it into the consumer `Task`.
///
/// After each `process(...)` call returns, execution resumes back on the main actor (the point the
/// consumer loop awaited from), so `apply(_:)` — which writes every `@Published` property — runs
/// with no further hop and no risk of interleaving with another frame's update.
@MainActor
final class TacitEngine: ObservableObject, EngineUIState {
    @Published private(set) var glyphState: GlyphState = .paused
    @Published var isEnabled: Bool
    /// Final-review finding I1 (spec §4: "users can disable the HUD entirely while keeping glyph
    /// feedback"): gates only `applyDispatchOutcome`'s `hudController.show`/`showError` calls — the
    /// glyph pulse (`pulseFired()`, called unconditionally from `apply(_:generation:)` for every
    /// fired event) is a separate, always-on confirmation and must keep working regardless of this
    /// setting. Persisted the same way as `isEnabled`: `UserDefaults`-backed, defaulting to `true`,
    /// written back on every change via the `$isHUDEnabled` sink wired in `init`.
    @Published var isHUDEnabled: Bool
    /// Gesture debug view (menu bar popover toggle "Show gesture debug view"): shows/hides
    /// `debugPanelController`'s floating panel and gates `debugSnapshot` population in
    /// `apply(_:generation:timestamp:)` — `UserDefaults`-backed under `"tacit.debugViewEnabled"`,
    /// defaulting to `false`, same pattern as `isHUDEnabled` above. Wired in `init` below: one sink
    /// persists the value and drives `debugPanelController.setVisible(_:)`, a second forwards every
    /// `debugSnapshot` change straight to the panel.
    @Published var isDebugViewEnabled: Bool
    /// M3 Task 7 (Settings tab sensitivity segmented control): the Settings tab's global
    /// arbitration sensitivity trim, `UserDefaults`-backed under `"tacit.sensitivity"`, defaulting
    /// to `.standard`. Every change swaps `PipelineCore`'s live tuning via the SAME actor path
    /// low light already uses — see `PipelineCore.setSensitivity(_:)`/`recomputeTuning()` — so a
    /// sensitivity change and a low-light flip always compose (sensitivity first, low light on
    /// top) rather than one silently clobbering the other.
    @Published var sensitivity: SensitivityTrim {
        didSet {
            guard sensitivity != oldValue else { return }
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityDefaultsKey)
            Task { [pipeline, sensitivity] in
                await pipeline?.setSensitivity(sensitivity)
            }
        }
    }
    /// M3 Task 7 (Settings tab camera picker): the selected camera's `AVCaptureDevice.uniqueID`,
    /// `UserDefaults`-backed under `"tacit.cameraID"`; `nil` means "use the default built-in
    /// wide-angle camera" (also `CaptureEngine.configureAndStart()`'s own hardcoded choice, so a
    /// nil selection needs no explicit switch at all — see `start()`'s startup-apply comment for
    /// why only a NON-nil persisted selection triggers one there). Every change here calls
    /// `CaptureEngine.switchCamera(to:)`, which itself no-ops while capture is `.unavailable` and
    /// falls back to the default device if the requested one no longer resolves (e.g. an external
    /// camera was unplugged) — this property is intentionally never validated against the live
    /// device list itself; that's `CaptureEngine`'s job, so this stays a dumb, persisted string.
    /// Clutch-optional setting (2026-08-24 product ruling): whether the fist clutch (a sustained
    /// `.looseFist` hold) must be armed before gestures fire. `true` requires it (the original
    /// behavior — see `PopoverView`'s "Require clutch (fist to arm)" toggle / `SettingsTab`'s
    /// mirror of it); `false` — the DEFAULT, per the user's own ask after their fist clutch
    /// misread (the log showed `arming → disarmed` bouncing ten times before ever arming) — skips
    /// the clutch entirely: any non-reserved gesture that clears debounce fires immediately, at a
    /// stricter confidence floor (`ArbitrationTuning.clutchOffConfidenceBoost`) as the
    /// false-positive brake. `UserDefaults`-backed under `"tacit.requiresClutch"`, same
    /// persist-on-change / apply-once-at-launch pattern as `sensitivity` above (see `start()`'s
    /// startup-apply comment) — every change also swaps `PipelineCore`'s live tuning via the SAME
    /// actor path sensitivity/low-light already use, so all three always compose deterministically
    /// (see `PipelineCore.recomputeTuning()`).
    @Published var requiresClutch: Bool {
        didSet {
            guard requiresClutch != oldValue else { return }
            UserDefaults.standard.set(requiresClutch, forKey: Self.requiresClutchDefaultsKey)
            TacitLog.engine.notice("requiresClutch -> \(self.requiresClutch, privacy: .public)")
            Task { [pipeline, requiresClutch] in
                await pipeline?.setClutchRequired(requiresClutch)
            }
        }
    }
    @Published var cameraID: String? {
        didSet {
            guard cameraID != oldValue else { return }
            UserDefaults.standard.set(cameraID, forKey: Self.cameraIDDefaultsKey)
            capture.switchCamera(to: cameraID)
        }
    }
    @Published private(set) var warning: String?
    /// True whenever `CaptureEngine.state == .unavailable` for ANY reason (permission denied, no
    /// camera present, couldn't open the device, etc.) — Task 20's `OnboardingView` needs this
    /// specifically, not the merged `warning`, because `warning` can also carry the unrelated
    /// Accessibility message (see `recomputeWarning()`) even while the camera itself is fine, and
    /// `glyphState == .paused` alone can't distinguish "capture hasn't been started yet" from
    /// "capture failed to start" — both collapse to the same resting glyph state.
    @Published private(set) var isCameraUnavailable = false
    @Published private(set) var lastEvent: GestureEvent?
    @Published private(set) var latestFrame: LandmarkFrame?
    /// Task 19's perform-to-preview: a raw, arbitration-BYPASSING candidate published once per
    /// frame while `isPreviewActive` is true — nil the rest of the time. This is deliberately not
    /// `lastEvent`/arbitration-derived: the Library's card detail strip needs to light up the
    /// instant a gesture is *performed*, with no clutch/arming/debounce in the way.
    @Published private(set) var previewCandidate: GestureCandidate?

    /// Gesture debug view: a per-frame snapshot of the pipeline's live state (raw classifier
    /// reading, arbitration phase, last fire, low-light/Accessibility status), populated by
    /// `apply(_:generation:timestamp:)` ONLY while `isDebugViewEnabled` is `true` — `nil` the rest
    /// of the time, and cleared immediately when the toggle turns off (see the `$isDebugViewEnabled`
    /// sink in `init`) rather than left showing a stale last reading. See `GestureDebug.swift`.
    @Published private(set) var debugSnapshot: GestureDebugSnapshot?

    /// Turns Task 19's perform-to-preview mode on/off. While `true`, `PipelineCore.process` also
    /// runs preview-scoped detectors and publishes their result via `previewCandidate` each frame;
    /// while `false` (the default), that extra work never runs, keeping the hot path clean. Settable
    /// by the UI — `CardDetailView`'s preview strip flips this on `onAppear` and off `onDisappear`
    /// (and therefore also when the card detail closes, since the strip unmounts with it).
    var isPreviewActive: Bool = false {
        didSet {
            guard isPreviewActive != oldValue else { return }
            if !isPreviewActive {
                // Clear immediately rather than waiting for the next frame's generation-guarded
                // `apply(_:generation:)` to catch up — otherwise a card's constellation could stay
                // lit for a beat after the strip has already disappeared.
                previewCandidate = nil
            }
            let active = isPreviewActive
            Task { [pipeline] in
                // Fresh preview-detector instances are created actor-side on every activation (see
                // `PipelineCore.setPreviewActive`), so no tap/swipe tracking state leaks between one
                // card's preview session and the next.
                await pipeline?.setPreviewActive(active)
            }
        }
    }

    let recorder: FixtureRecorder

    /// The persistent gesture→action mapping store (spec §3.6, Task 21 unification): `TacitEngine`
    /// is the SINGLE owner of the app's one `MappingStore` instance — the Library window and
    /// onboarding read/write this exact object (`TacitApp` passes `engine.mappingStore` to both),
    /// and `handleFire(_:)` below reads it on every fired event. No second instance exists
    /// anywhere in the app.
    let mappingStore = MappingStore()
    /// The live macOS side-effect environment — kept as its own property (not just wrapped inside
    /// `actionDispatcher`) so M3 Task 9's hold-began/hold-ended paths can call `postKeyDown`/
    /// `postKeyUp` DIRECTLY, bypassing `ActionDispatcher.dispatch(_:)` entirely (that method's
    /// `.holdKeystroke` case is only the normal-fire-path fallback — see its doc comment).
    private let actionEnvironment = LiveActionEnvironment.make()
    /// Routes a fired, bound `TacitAction` to its real macOS side effect. Constructed once with
    /// the live environment — see `handleFire(_:)` for the split between actions `dispatch(_:)` is
    /// called for SYNCHRONOUSLY on the main actor (`.keystroke`/`.holdKeystroke`/`.toggleKeystroke`
    /// — ordering, not blocking, is what's at stake for these) and actions it's still only ever
    /// called for from a `Task.detached` (`.launchApp`/`.openURL`/`.runShortcut`/
    /// `.focusTextInput`/`.switchApp` — blocking is what's at stake for these).
    private let actionDispatcher: ActionDispatcher
    /// The one HUD panel instance for real gesture fires, shown/errored by `handleFire(_:)`.
    /// (`PopoverView`'s ⌥-debug section keeps its own separate, never-wired `HUDController` for
    /// eyeballing motion manually — see that file's doc comment — so the two never collide.)
    let hudController = HUDController()
    /// The gesture debug view's one floating panel instance — see `GestureDebugPanel.swift`'s doc
    /// comment for the full design; wired to `isDebugViewEnabled`/`debugSnapshot` in `init` below,
    /// the same "owned directly by the engine" pattern as `hudController` above.
    let debugPanelController = GestureDebugPanelController()

    private static let enabledDefaultsKey = "tacit.enabled"
    private static let hudEnabledDefaultsKey = "tacit.hudEnabled"
    private static let debugViewEnabledDefaultsKey = "tacit.debugViewEnabled"
    private static let sensitivityDefaultsKey = "tacit.sensitivity"
    private static let cameraIDDefaultsKey = "tacit.cameraID"
    private static let requiresClutchDefaultsKey = "tacit.requiresClutch"
    /// Task 21 controller ruling (R4): set the first time — ever — a mapped gesture successfully
    /// performs its action, so that one fire (and only that one) can ask the HUD for a slightly
    /// grander constellation draw-on. Lives here, not in `TacitCore` (no `UserDefaults` there).
    private static let firstFireCelebratedKey = "tacit.firstFireCelebrated"
    /// Code review 2026-08-27, Finding 3: the `.toggleKeystroke` latch's currently-engaged
    /// `KeyChord`, JSON-encoded via its own `Codable` conformance (`KeyChord.swift:6`). Written by
    /// `persistLatchedChord(_:)` the instant a real key-down is posted, cleared by
    /// `clearPersistedLatchedChord()` the instant that key is released. `TacitEngine.init` reads
    /// this before anything else and replays a leftover key-up unconditionally — cold-start
    /// recovery for the one release hook that can't be relied on:
    /// `NSApplication.willTerminateNotification` (handled at `handleApplicationWillTerminate()`)
    /// never fires on SIGKILL or a crash, so without this key a latched modifier from that class
    /// of exit had no recovery path at all.
    private static let latchedChordDefaultsKey = "tacit.latchedChord"
    /// Final-review finding F1: the v1 set of static poses that support hold lifecycle
    /// (began/ended), shared as the SINGLE source of truth between `holdTracker`'s `init` below
    /// and `handleFire(_:)`'s holdable-`.holdKeystroke` guard — previously only the `HoldTracker`
    /// init knew this set, so `handleFire(_:)` had no way to ask "is this gesture's hold path
    /// going to own this fire" and dispatched every fire's binding unconditionally, racing the
    /// hold path's own synchronous key-down (see `handleFire(_:)`'s doc comment for the full
    /// story).
    static let holdableGestures: Set<GestureID> = [.indexPoint, .thumbsUp, .victory]

    private let capture = CaptureEngine()
    private var pipeline: PipelineCore?

    private var frameContinuation: AsyncStream<(CVPixelBuffer, TimeInterval)>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var fireResetTask: Task<Void, Never>?
    private var pauseResumeTask: Task<Void, Never>?
    private var accessibilityCheckTask: Task<Void, Never>?
    private var hasStarted = false

    /// True only while the current `capture` pause was raised by `handleScreenLockSignal`/
    /// `handleDisplaySleepSignal` below (screen locked or display asleep) — never by the user's own
    /// master toggle or "Pause for an Hour". Gates the resume performed on an unlock/wake signal
    /// (spec §3.1/§6: locking the screen must pause detection, and unlocking must resume it, but
    /// ONLY the pause it itself caused): a screen unlock/wake must never override a pause the user
    /// asked for on purpose. Set `false` unconditionally by `handleEnabledChange` and `pause(for:)`
    /// — the two user-initiated pause paths — so a lock that happens to overlap with either of
    /// those can never sneak an unwanted auto-resume in later.
    ///
    /// Also written to `true` by `pause(for:)`'s own timer completion when the hour elapses while
    /// `isSystemBlocked` is still `true`: that hands the eventual resume off to the next
    /// unlock/wake signal instead of resuming immediately behind a locked screen.
    private var isScreenLockPaused = false
    /// True while the screen is CURRENTLY locked — set only by `handleScreenLockSignal`
    /// (`com.apple.screenIsLocked`), cleared ONLY by `handleScreenUnlockSignal`
    /// (`com.apple.screenIsUnlocked`). Kept independent of `isDisplayAsleep` below: post-review fix
    /// #2 found that macOS commonly fires `screensDidWake` BEFORE `screenIsUnlocked` (waking a
    /// locked Mac shows the password screen first, still locked) — a single merged "is the screen
    /// currently hidden" flag cleared by EITHER wake or unlock would go `false` at the wake moment
    /// while the password screen is still up, letting a resume slip through behind the lock screen.
    /// Two independent flags, combined via `isSystemBlocked` below, fix that: waking a still-locked
    /// Mac clears only `isDisplayAsleep`, and `isSystemBlocked` stays `true` (from this flag) until
    /// the real unlock.
    private var isScreenLockedFlag = false
    /// True while the display is CURRENTLY asleep — set only by `handleDisplaySleepSignal`
    /// (`screensDidSleepNotification`), cleared ONLY by `handleDisplayWakeSignal`
    /// (`screensDidWakeNotification`). See `isScreenLockedFlag`'s doc comment for why this is kept
    /// as its own independent flag rather than merged with it.
    private var isDisplayAsleep = false
    /// "Is anything currently blocking the user from seeing the screen" — the OR of the two
    /// independent flags above. This, not either flag alone, is what `pause(for:)`'s timer
    /// completion and the unlock/wake resume path check: a lock-then-sleep-then-wake-while-still-
    /// locked sequence must stay blocked (via `isScreenLockedFlag`) even though `isDisplayAsleep`
    /// already cleared on the wake; a plain sleep-with-no-lock must resume on wake alone, since
    /// `isScreenLockedFlag` was never set in that case (`isSystemBlocked` gives this for free — no
    /// separate "was it ever locked" bookkeeping needed).
    private var isSystemBlocked: Bool { isScreenLockedFlag || isDisplayAsleep }
    /// Tokens for the block-based observers registered by `registerForScreenStateNotifications()`,
    /// paired with the center each was registered on (`DistributedNotificationCenter` is a
    /// `NotificationCenter` subclass, so both fit this one array) — removed in `deinit`. Declared
    /// `nonisolated(unsafe)` (matching `CaptureEngine.onFrameStorage`'s rationale) purely so `deinit`
    /// — which, like every Swift `deinit`, runs nonisolated even on a `@MainActor` class — can read
    /// it to remove the observers; every other access is from `init`/`registerForScreenStateNotifications()`
    /// on the main actor, and by the time `deinit` runs nothing else can be touching this instance.
    private nonisolated(unsafe) var systemStateObserverTokens: [(NotificationCenter, NSObjectProtocol)] = []

    /// The three components `warning` is derived from (spec §6): a camera-side message (from
    /// `CaptureState`), a low-light message (M3 Task 6, from `lowLightPolicy` below), and an
    /// Accessibility-side message (from the poll wired in `init` below). Kept separate rather
    /// than overwriting one `warning` in place so no source can clobber another's message —
    /// `recomputeWarning()` is the only place all three are combined, in a deliberate precedence
    /// order: **camera unavailable > low light > accessibility**. Camera wins outright because it
    /// blocks recognition entirely (nothing downstream works without frames); low light outranks
    /// accessibility because it's a live signal about the CURRENT gesture-recognition conditions
    /// (a dim room degrades every gesture, right now), whereas the accessibility gap only affects
    /// keystroke actions specifically and persists regardless of lighting — the more acute,
    /// currently-degrading condition is shown first.
    private var captureWarning: String?
    /// M3 Task 6 (spec §6 low-light row): non-nil exactly while `lowLightPolicy.isLowLight` is
    /// `true`, holding the fixed copy "More light helps Tacit see your hand." Set/cleared only in
    /// `handleLuma(_:at:)`, on a hysteresis FLIP — never recomputed from scratch on every sample,
    /// so `recomputeWarning()` can treat this exactly like `captureWarning`/`accessibilityWarning`.
    private var lowLightWarning: String?
    private var accessibilityWarning: String?

    /// M3 Task 6: pure hysteresis policy (`Sources/TacitCore/LowLightPolicy.swift`) fed sampled
    /// luma from `CaptureEngine.onLuma` — see `handleLuma(_:at:)`. Lives here (not on
    /// `PipelineCore`) because it drives both `warning` (main-actor UI state) and the arbitration
    /// tuning swap; `PipelineCore.setLowLight` is only ever told the resulting boolean, never given
    /// this policy itself.
    private var lowLightPolicy = LowLightPolicy()
    /// True while at least one ENABLED binding's action `requiresAccessibility` — recomputed
    /// whenever `mappingStore.bindings` changes (wired below, in `init`). Kept as a stored flag
    /// (rather than re-scanning bindings on every 5 s poll tick) so the poll loop only ever has to
    /// ask one question: is Accessibility trusted right now.
    private var enabledKeystrokeBindingExists = false
    /// Diagnostic only: last `AXIsProcessTrusted()` result logged by `recomputeAccessibilityWarning()`,
    /// so the 5 s poll only logs on an actual flip rather than spamming the log stream every tick.
    private var lastLoggedAccessibilityTrusted: Bool?

    /// M3 Task 9: tracks whether a holdable static pose (`Self.holdableGestures`) is currently
    /// being held, independent of whether it's bound to `.holdKeystroke` — see
    /// `apply(_:generation:timestamp:)`'s doc comment for the full per-frame wiring, and
    /// `HoldTracker`'s own doc comment for why a stuck-down key is impossible by construction.
    private var holdTracker = HoldTracker(holdableGestures: TacitEngine.holdableGestures)
    /// Mirrors `holdTracker`'s own began/ended state — `true` from the frame a `.began` is seen
    /// through the frame its matching `.ended` is seen, regardless of binding. Used ONLY to decide
    /// whether to keep extending the arbitration command window each frame (a hold not bound to
    /// `.holdKeystroke` still deserves the window staying open, since the user is still
    /// deliberately holding a pose in an armed session either way).
    private var isHoldActive = false
    /// The `KeyChord` currently held down via `.holdKeystroke`, or `nil`. Set the instant a hold's
    /// `.began` triggers a real `postKeyDown` (i.e. the held gesture IS bound to an enabled
    /// `.holdKeystroke`, and Accessibility is trusted); cleared the instant the matching `.ended`
    /// triggers the paired `postKeyUp`. Captured at `.began` time rather than re-read from
    /// `mappingStore` at `.ended` time on purpose: a rebind mid-hold (changing the gesture's
    /// binding, or disabling it) must still release the EXACT key that went down, never whatever
    /// the binding says NOW — releasing the wrong key would either leave the real key stuck or
    /// spuriously release an unrelated one.
    private var activeHoldChord: KeyChord?

    /// Workhorse-remap plan, Task 4: the `.toggleKeystroke` latch. Pure state in `TacitCore`;
    /// this engine owns the key posting around it. See `releaseLatchIfNeeded()` for the complete
    /// release-path inventory (the toggle's answer to `endActiveHoldIfNeeded()`).
    private var keyLatch = KeyLatch()
    /// The chord currently latched down via `.toggleKeystroke`, or `nil` — published so the
    /// popover can show its "Release <key>" safety row (Task 5). Mirrors `keyLatch.active?.chord`.
    @Published private(set) var latchedChord: KeyChord?

    /// Latest arbitration phase seen from the pipeline, kept outside `PipelineCore` so
    /// `recomputeGlyphState()` can be driven by capture-state changes too (which arrive via
    /// Combine, not via a frame).
    private var lastArbitrationState: ArbitrationState = .disarmed

    /// Bumped every time the pipeline is reset (see `handleCaptureStateChange`). Each in-flight
    /// `process(...)` call is tagged with the generation current at the moment it was submitted;
    /// `apply(_:generation:)` drops any result whose tag no longer matches. Without this, a frame
    /// that started processing right before a pause/reset could resolve *after* the reset and
    /// briefly resurrect a stale `.armed` arbitration state into the freshly-resumed `.running`
    /// state — a spurious "armed without a clutch" flash. Tagging at submission (not at the
    /// pipeline's start()-time constant) is what makes the drop deterministic: it doesn't matter
    /// how long `process(...)` takes, only whether a reset happened while it was in flight.
    private var pipelineGeneration = 0

    private var cancellables: Set<AnyCancellable> = []

    init(recorder: FixtureRecorder = FixtureRecorder()) {
        // Code review 2026-08-27, Finding 3: cold-start recovery, run before anything else below.
        // If the previous process left a chord latched — crashed or was force-quit while a
        // `.toggleKeystroke` held a key down — replay its key-up now and clear the record.
        // Unconditional on Accessibility trust on purpose: this is the one release path that
        // isn't gated on it, matching the unconditional-release convention every other
        // stuck-key chokepoint already uses (`releaseLatchIfNeeded()`, `handleHoldEnded(_:)`); a
        // `postKeyUp` that fails silently because trust was revoked between launches is harmless
        // either way. Safe to use `actionEnvironment` here even though `self` isn't fully set up
        // yet: it's a stored property with its own default value (`LiveActionEnvironment.make()`,
        // declared above), so — unlike `recorder`/`actionDispatcher` just below, which this very
        // initializer assigns — it's already valid before this body starts running.
        if let orphanedData = UserDefaults.standard.data(forKey: Self.latchedChordDefaultsKey),
           let orphaned = try? JSONDecoder().decode(KeyChord.self, from: orphanedData) {
            _ = actionEnvironment.postKeyUp(orphaned)
            UserDefaults.standard.removeObject(forKey: Self.latchedChordDefaultsKey)
            TacitLog.actions.notice("cold-start recovery: orphaned latch chord=\(orphaned.display, privacy: .public) released")
        }

        self.recorder = recorder
        self.actionDispatcher = ActionDispatcher(environment: actionEnvironment)
        let stored = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool
        self.isEnabled = stored ?? true
        let storedHUDEnabled = UserDefaults.standard.object(forKey: Self.hudEnabledDefaultsKey) as? Bool
        self.isHUDEnabled = storedHUDEnabled ?? true
        let storedDebugViewEnabled = UserDefaults.standard.object(forKey: Self.debugViewEnabledDefaultsKey) as? Bool
        self.isDebugViewEnabled = storedDebugViewEnabled ?? false
        let storedSensitivity = UserDefaults.standard.string(forKey: Self.sensitivityDefaultsKey)
            .flatMap(SensitivityTrim.init(rawValue:))
        self.sensitivity = storedSensitivity ?? .standard
        let storedRequiresClutch = UserDefaults.standard.object(forKey: Self.requiresClutchDefaultsKey) as? Bool
        self.requiresClutch = storedRequiresClutch ?? false
        self.cameraID = UserDefaults.standard.string(forKey: Self.cameraIDDefaultsKey)

        capture.$state
            .sink { [weak self] state in
                self?.handleCaptureStateChange(state)
            }
            .store(in: &cancellables)

        $isEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.handleEnabledChange(enabled)
            }
            .store(in: &cancellables)

        $isHUDEnabled
            .dropFirst()
            .sink { enabled in
                UserDefaults.standard.set(enabled, forKey: Self.hudEnabledDefaultsKey)
            }
            .store(in: &cancellables)

        $isDebugViewEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                UserDefaults.standard.set(enabled, forKey: Self.debugViewEnabledDefaultsKey)
                TacitLog.engine.notice("debug view -> \(enabled, privacy: .public)")
                self.debugPanelController.setVisible(enabled)
                if !enabled {
                    // Don't leave the panel's last reading visible/stale for the next enable —
                    // matches `debugSnapshot`'s own doc comment.
                    self.debugSnapshot = nil
                }
            }
            .store(in: &cancellables)

        // Forwards every `debugSnapshot` change straight to the panel — `debugPanelController`
        // never reads `TacitEngine` directly (see that type's doc comment), so this sink is the
        // only path a new snapshot takes to reach the SwiftUI view.
        $debugSnapshot
            .sink { [weak self] snapshot in
                self?.debugPanelController.update(snapshot)
            }
            .store(in: &cancellables)

        // Sync the panel's initial visibility immediately: `dropFirst()` above only reacts to a
        // CHANGE, so a persisted `isDebugViewEnabled == true` (the default this feature ships with,
        // per the user's request to leave it on) needs this explicit call to actually show the
        // panel at launch rather than waiting for the user to toggle it off and back on.
        debugPanelController.setVisible(isDebugViewEnabled)

        // Spec §6's Accessibility-warning derivation (Task 20), unified onto the single owned
        // `mappingStore` (Task 21): recompute strategy is a periodic 5 s poll while any enabled
        // binding requires Accessibility, PLUS an immediate recompute whenever `bindings` itself
        // changes (enabling/disabling/rebinding a keystroke gesture shouldn't wait up to 5 s to
        // show or clear the warning). `AXIsProcessTrusted()` has no publisher of its own, so
        // polling is the only way to notice a grant/revoke made in System Settings while Tacit
        // keeps running.
        mappingStore.$bindings
            .sink { [weak self] bindings in
                guard let self else { return }
                self.enabledKeystrokeBindingExists = bindings.values.contains {
                    $0.enabled && ($0.action?.requiresAccessibility ?? false)
                }
                self.recomputeAccessibilityWarning()

                // Toggle latch: the latched gesture's binding changed out from under it.
                if let active = self.keyLatch.active {
                    let binding = bindings[active.gesture]
                    let stillLatchBound = binding?.enabled == true && binding?.action == .toggleKeystroke(active.chord)
                    if !stillLatchBound {
                        self.releaseLatchIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)

        accessibilityCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.recomputeAccessibilityWarning()
                try? await Task.sleep(for: .seconds(5))
            }
        }

        registerForScreenStateNotifications()

        // 2026-08-24 product ruling: force `AppSwitcher.shared` into existence now (rather than
        // waiting for the first swipe) so its MRU list is already seeded and its `NSWorkspace`
        // notification observers are already registered by the time a flip actually happens —
        // the first swipe right/left after launch shouldn't fall back to a cold, just-seeded list.
        _ = AppSwitcher.shared

        TacitLog.engine.notice("engine init: AXIsProcessTrusted=\(AXIsProcessTrusted(), privacy: .public)")
    }

    deinit {
        for (center, token) in systemStateObserverTokens {
            center.removeObserver(token)
        }
    }

    // MARK: - Lifecycle

    /// Wires `capture.onFrame` (must happen before `capture.start()`, on the main actor — see
    /// `CaptureEngine`'s assertion) and starts the single pipeline-consuming `Task`. Safe to call
    /// more than once; only the first call has any effect.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // `.bufferingNewest(1)` — not the default `.unbounded` — so a Vision stall (or any other
        // slow frame) drops backlog instead of queueing it: without this, a stall would make the
        // pipeline dutifully replay every buffered stale frame afterward instead of tracking real
        // time once it catches up.
        let (stream, continuation) = AsyncStream<(CVPixelBuffer, TimeInterval)>.makeStream(
            of: (CVPixelBuffer, TimeInterval).self,
            bufferingPolicy: .bufferingNewest(1)
        )
        frameContinuation = continuation

        let pipeline = PipelineCore()
        self.pipeline = pipeline

        // M3 Task 7: a freshly-constructed `PipelineCore` always starts at `.standard` (see its
        // `currentSensitivity` default) regardless of what the user previously persisted under
        // `"tacit.sensitivity"` — apply that persisted trim once, here, so a restart doesn't
        // silently revert a saved "Relaxed"/"Eager" preference back to standard until the user
        // re-visits Settings. Harmless (a same-value recompute) when the persisted value is
        // already `.standard`.
        Task { [pipeline, sensitivity] in
            await pipeline.setSensitivity(sensitivity)
        }

        // Clutch-optional setting: same rationale as the sensitivity apply-once above — a
        // freshly-constructed `PipelineCore` always starts `currentRequiresClutch == true`
        // regardless of what's persisted under `"tacit.requiresClutch"` (default `false`), so a
        // restart must not silently revert the user back to requiring the clutch until they
        // re-visit the toggle.
        Task { [pipeline, requiresClutch] in
            await pipeline.setClutchRequired(requiresClutch)
        }

        capture.onFrame = { pixelBuffer, timestamp in
            continuation.yield((pixelBuffer, timestamp))
        }

        // M3 Task 6: fires on the capture queue roughly every 2s (see `CaptureEngine.onLuma`'s doc
        // comment) — hop to the main actor before touching `lowLightPolicy`/`warning`, matching
        // this file's established `Task { @MainActor in ... }` convention for every other
        // capture-queue-originated callback (contrast the `@objc` notification handlers in
        // `CaptureEngine` itself, which rely on a *documented* main-thread guarantee this callback
        // doesn't have).
        capture.onLuma = { [weak self] luma, timestamp in
            Task { @MainActor in
                self?.handleLuma(luma, at: timestamp)
            }
        }

        pipelineTask = Task { @MainActor [weak self] in
            for await (pixelBuffer, timestamp) in stream {
                guard let self else { return }
                // Read the generation *before* the (potentially slow) process() call, so a
                // reset that happens while this frame is in flight is detected on return — see
                // `apply(_:generation:)`.
                let generation = self.pipelineGeneration
                let result = await pipeline.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
                self.apply(result, generation: generation, timestamp: timestamp)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.capture.start()
            // M3 Task 7: apply a persisted non-default camera selection once the session exists.
            // `configureAndStart()` always opens the default built-in wide-angle camera itself, so
            // a `nil` `cameraID` (never customized, or explicitly reset to default) needs no call
            // here at all — only a persisted, non-nil selection has to be switched to.
            // `CaptureEngine.switchCamera(to:)` itself no-ops if `capture.start()` left `state` at
            // `.unavailable` (no camera/permission denied), keeping that state truthful.
            if let cameraID = self.cameraID {
                self.capture.switchCamera(to: cameraID)
            }
            if !self.isEnabled {
                self.capture.pause(reason: "Paused")
            }
        }
    }

    /// "Pause for an Hour" (or any other duration): pauses capture immediately and schedules a
    /// resume after `duration`. Independent of the `isEnabled` master toggle — but if the user
    /// flips that toggle (either direction) before the timer fires, `handleEnabledChange` cancels
    /// this pending resume so the two mechanisms never fight over capture state.
    ///
    /// Post-review fix: the completion no longer resumes unconditionally. If `isSystemBlocked` is
    /// still `true` (screen locked and/or display asleep) when the timer fires, resuming here would
    /// restart capture behind a locked screen — exactly what I2 exists to prevent. Instead it hands
    /// off: marks `isScreenLockPaused = true` so the eventual unlock/wake signal (whichever one
    /// actually clears `isSystemBlocked`) performs the resume itself once the screen actually comes
    /// back.
    ///
    /// `userPauseEndsAt` mirrors this pause's deadline for the popover's state-aware pause/resume
    /// row (nil means no user pause is active); it's cleared everywhere `pauseResumeTask` is
    /// cancelled or completes, so the row never shows "Resume" once capture is actually running.
    @Published private(set) var userPauseEndsAt: Date?

    func pause(for duration: TimeInterval) {
        pauseResumeTask?.cancel()
        // User-initiated: always wins over a pending screen-lock auto-resume (see
        // `isScreenLockPaused`'s doc comment).
        isScreenLockPaused = false
        capture.pause(reason: "Paused")
        userPauseEndsAt = Date().addingTimeInterval(duration)
        pauseResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.pauseResumeTask = nil
            self.userPauseEndsAt = nil
            if self.isSystemBlocked {
                self.isScreenLockPaused = true
                return
            }
            self.capture.resume()
        }
    }

    /// Popover "Resume" row (shown in place of "Pause for an hour" while `userPauseEndsAt` is set):
    /// cancels the pending auto-resume timer and resumes immediately. User-initiated, so it wins
    /// over a pending screen-lock auto-resume the same way `pause(for:)`/`handleEnabledChange` do —
    /// except when `isSystemBlocked` is still true, in which case it hands off to the next
    /// unlock/wake signal exactly like `pause(for:)`'s own timer completion does above.
    func resumeFromUserPause() {
        TacitLog.capture.notice("user pause -> resume")
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        userPauseEndsAt = nil
        isScreenLockPaused = false
        if isSystemBlocked {
            isScreenLockPaused = true
            return
        }
        capture.resume()
    }

    // MARK: - isEnabled / capture-state plumbing

    private func handleEnabledChange(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        userPauseEndsAt = nil
        // User-initiated: always wins over a pending screen-lock auto-resume (see
        // `isScreenLockPaused`'s doc comment).
        isScreenLockPaused = false
        if enabled {
            // Deliberately resumes unconditionally, even if `isSystemBlocked` is still true: this is
            // an explicit user action (flipping the master toggle back on), not a timer firing in
            // the background, so per re-review it's allowed to override a screen-lock pause —
            // unlike `pause(for:)`'s deferred timer-completion resume above.
            capture.resume()
        } else {
            capture.pause(reason: "Paused")
        }
        recomputeGlyphState()
    }

    // MARK: - Screen lock / display sleep (spec §3.1/§6, final review finding I2)

    /// Wires the two independent macOS signals for "the user has stepped away and the screen is no
    /// longer visible": `DistributedNotificationCenter`'s undocumented-but-long-stable
    /// `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked` (fast user switching / login window
    /// lock) and `NSWorkspace`'s `screensDidSleepNotification`/`screensDidWakeNotification` (display
    /// sleep via Energy Saver, closing a laptop lid with an external display, etc). Each of the four
    /// notifications gets its own handler (`handleScreenLockSignal`/`handleScreenUnlockSignal`/
    /// `handleDisplaySleepSignal`/`handleDisplayWakeSignal`) that updates its OWN independent flag
    /// (`isScreenLockedFlag`/`isDisplayAsleep`) before delegating to the shared
    /// `pauseIfRunning(reason:)`/`resumeIfSystemInitiatedAndUnblocked()` pair — deliberately NOT
    /// merged into one "is the screen hidden" flag/pause-signal pair, because macOS can fire
    /// `screensDidWake` before `com.apple.screenIsUnlocked` (waking a locked Mac shows the password
    /// screen first, still locked): a merged flag cleared by either wake or unlock would go `false`
    /// at the wake moment and let a resume slip through behind the lock screen. `isSystemBlocked`
    /// (the OR of both flags) is what the shared resume half and `pause(for:)`'s timer completion
    /// actually check, so either signal alone still correctly means "nobody is looking at the screen
    /// right now" (spec §3.1/§6) for the PAUSE side, while the RESUME side requires both to clear.
    ///
    /// Owner choice: this lives on `TacitEngine`, not `CaptureEngine`, because reconciling this
    /// signal against the OTHER two things that can pause capture — the master `isEnabled` toggle
    /// and "Pause for an Hour" — requires `isScreenLockPaused` plus the two call sites above, and
    /// `TacitEngine` already owns exactly that reconciliation (see `pauseResumeTask` cancellation in
    /// `handleEnabledChange`/`pause(for:)`). `CaptureEngine` only knows about ONE pause at a time
    /// (`state`'s reason string), so it has no way to tell "the user asked for this" apart from "the
    /// screen just locked" — this class is the only place both are visible together.
    ///
    /// Threading: `DistributedNotificationCenter` selector/block callbacks fire on whatever thread
    /// posted the notification — NOT guaranteed to be the main thread (contrast `AVCaptureSession`'s
    /// notifications, which `CaptureEngine`'s header doc explains ARE documented main-thread-only,
    /// letting its handlers touch `@MainActor` state directly). These observers are block-based
    /// (`addObserver(forName:object:queue:using:)` with `queue: nil`, i.e. "caller's thread") and
    /// therefore hop explicitly via `Task { @MainActor in ... }` before touching any actor-isolated
    /// state, matching this file's documented `Task { @MainActor in ... }` convention rather than
    /// the selector-based exception `CaptureEngine` relies on. `NSWorkspace`'s sleep/wake
    /// notifications are documented main-thread-only in practice, but are hopped the same way here
    /// for one uniform, always-correct pattern instead of two different threading rules side by side.
    private func registerForScreenStateNotifications() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        let lockToken = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenLockSignal()
            }
        }
        let unlockToken = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenUnlockSignal()
            }
        }
        let sleepToken = workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplaySleepSignal()
            }
        }
        let wakeToken = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayWakeSignal()
            }
        }

        // M3 Task 9 ended-path: app quit. `NSApplication.willTerminateNotification` is documented
        // to fire on the main thread, so — unlike the four observers above, which deliberately
        // hop via `Task { @MainActor in ... }` because their sources aren't guaranteed main-thread
        // — this handler runs SYNCHRONOUSLY via `MainActor.assumeIsolated`, not a `Task`: the
        // whole point is that the final key-up has actually been attempted before this callback
        // returns and the process exits, and a freshly spawned `Task` this late has no guarantee
        // of ever getting a turn to run before `exit()` is called. See
        // `handleApplicationWillTerminate`'s doc comment for the caveats that remain regardless
        // (e.g. a forced quit/SIGKILL skips this notification entirely).
        let willTerminateToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationWillTerminate()
            }
        }

        systemStateObserverTokens = [
            (distributed, lockToken),
            (distributed, unlockToken),
            (workspace, sleepToken),
            (workspace, wakeToken),
            (NotificationCenter.default, willTerminateToken),
        ]
    }

    /// `com.apple.screenIsLocked`: sets `isScreenLockedFlag` unconditionally (independent
    /// bookkeeping — see its doc comment), then defers to `pauseIfRunning(reason:)`.
    private func handleScreenLockSignal() {
        isScreenLockedFlag = true
        pauseIfRunning(reason: "Screen locked")
    }

    /// `com.apple.screenIsUnlocked`: clears `isScreenLockedFlag` unconditionally, then defers to
    /// `resumeIfSystemInitiatedAndUnblocked()` — the ONLY place either lock flag is cleared, per
    /// post-review fix #2 (macOS can fire `screensDidWake` before this, while still locked; this
    /// notification is the true "the user is back" signal for the lock side).
    private func handleScreenUnlockSignal() {
        isScreenLockedFlag = false
        resumeIfSystemInitiatedAndUnblocked()
    }

    /// `screensDidSleepNotification`: sets `isDisplayAsleep` unconditionally, then defers to
    /// `pauseIfRunning(reason:)`.
    private func handleDisplaySleepSignal() {
        isDisplayAsleep = true
        pauseIfRunning(reason: "Display asleep")
    }

    /// `screensDidWakeNotification`: clears `isDisplayAsleep` unconditionally, then defers to
    /// `resumeIfSystemInitiatedAndUnblocked()`. Post-review fix #2: this notification commonly
    /// fires BEFORE `com.apple.screenIsUnlocked` when waking a locked Mac (the password screen
    /// shows first, screen still locked) — clearing only `isDisplayAsleep` here, not
    /// `isScreenLockedFlag`, is what keeps `isSystemBlocked` `true` (and therefore keeps capture
    /// paused) through that gap. A plain sleep with no lock involved never set `isScreenLockedFlag`
    /// in the first place, so this wake alone correctly clears `isSystemBlocked` and resumes.
    private func handleDisplayWakeSignal() {
        isDisplayAsleep = false
        resumeIfSystemInitiatedAndUnblocked()
    }

    /// Shared pause half for the two "something just started blocking the screen" signals above.
    /// Only pauses (and only marks the pause as system-initiated via `isScreenLockPaused`) while
    /// capture is actually `.running` — if it's already `.paused` (user disabled it, or mid "Pause
    /// for an Hour") or `.unavailable` (no camera), there's nothing to do to `capture`, and
    /// critically `isScreenLockPaused` must stay `false` so a later unlock/wake never resumes a
    /// pause it didn't cause. The `isScreenLockedFlag`/`isDisplayAsleep` bookkeeping above already
    /// happened unconditionally in the caller, regardless of this guard.
    private func pauseIfRunning(reason: String) {
        guard case .running = capture.state else { return }
        isScreenLockPaused = true
        capture.pause(reason: reason)
    }

    /// Shared resume half for the two "something just stopped blocking the screen" signals above.
    /// Resumes only if BOTH: (1) `isSystemBlocked` is now `false` — the OTHER flag isn't still
    /// holding the screen blocked (post-review fix #2's wake-before-unlock ordering) — and (2)
    /// `isScreenLockPaused` is still set, i.e. nothing user-initiated (master toggle, "Pause for an
    /// Hour") has happened since the pause, AND `pause(for:)`'s timer completion didn't already
    /// resume before this fired. Also what performs the deferred resume when `pause(for:)`'s timer
    /// elapsed while `isSystemBlocked` was still true (see that method's doc comment).
    /// `capture.resume()` itself only transitions out of `.paused`, so this is additionally safe
    /// even if `state` somehow became `.unavailable` in between.
    private func resumeIfSystemInitiatedAndUnblocked() {
        guard !isSystemBlocked else { return }
        guard isScreenLockPaused else { return }
        isScreenLockPaused = false
        capture.resume()
    }

    private func handleCaptureStateChange(_ state: CaptureState) {
        TacitLog.capture.notice("capture state -> \(String(describing: state), privacy: .public)")
        updateWarning(for: state)
        if !isRunning(state) {
            // Capture stopped (paused, interrupted, or unavailable): drop any stale arbitration
            // progress so a later resume starts clean from `.disarmed` rather than momentarily
            // flashing whatever phase (e.g. `.armed`) was in effect right before the pause.
            // Bumping the generation here — before the reset actually completes on the pipeline
            // actor — is what lets `apply(_:generation:timestamp:)` deterministically discard any
            // frame already in flight, no matter when it resolves.
            pipelineGeneration += 1
            lastArbitrationState = .disarmed
            // No live frame is coming while capture is stopped: a stale preview candidate must not
            // keep a card lit (requirement 5 — a paused strip shows the dimmed canned frame only).
            previewCandidate = nil
            if let pipeline {
                Task { await pipeline.reset() }
            }
            // M3 Task 9 ended-path: capture stopping is THE chokepoint for a hold ending on
            // capture pause/unavailable, screen lock, display sleep, and `isEnabled` off — every
            // one of those funnels into `capture.pause(...)` and lands here (see
            // `endActiveHoldIfNeeded()`'s doc comment for the complete ended-path inventory). No
            // more frames arrive once capture stops, so this is the ONLY place those paths can
            // still end a hold — the per-frame check in `apply(_:generation:timestamp:)` never
            // gets another chance to run.
            endActiveHoldIfNeeded()
            // Toggle latch: same chokepoint, same reasons (see releaseLatchIfNeeded()).
            releaseLatchIfNeeded()
        }
        recomputeGlyphState()
    }

    private func updateWarning(for state: CaptureState) {
        switch state {
        case .unavailable(let reason):
            captureWarning = reason == "Camera access denied"
                ? "Camera access needed — open System Settings"
                : reason
            isCameraUnavailable = true
        case .running, .paused:
            captureWarning = nil
            isCameraUnavailable = false
        }
        recomputeWarning()
    }

    /// `warning`'s single point of combination (spec §6). Precedence, most acute first: **camera
    /// unavailable > low light > accessibility** — see `captureWarning`'s doc comment for the full
    /// rationale. A plain `??` chain in that order is sufficient: at most one of the three is ever
    /// non-nil in the common case, but if more than one is true at once (e.g. a dim room AND a
    /// missing Accessibility grant), only the highest-priority message is shown, exactly as the
    /// pre-M3 camera-vs-accessibility chain already did.
    private func recomputeWarning() {
        warning = captureWarning ?? lowLightWarning ?? accessibilityWarning
    }

    // MARK: - Low light (spec §6, M3 Task 6)

    /// Feeds one sampled luma reading into `lowLightPolicy` and, only on a hysteresis FLIP (the
    /// common case is no flip — most samples just confirm the current state), updates `warning`
    /// and asks `PipelineCore` to swap its arbitration tuning accordingly.
    ///
    /// Order matters slightly here but isn't safety-critical either way: `lowLightWarning`/
    /// `recomputeWarning()` update synchronously (so the UI reflects the new state immediately),
    /// while the tuning swap is dispatched into a `Task` awaiting the actor-isolated
    /// `PipelineCore.setLowLight` — see that method's doc comment for why the swap itself is race-
    /// free regardless of when this `Task` actually runs relative to an in-flight frame.
    private func handleLuma(_ luma: Double, at timestamp: TimeInterval) {
        let wasLowLight = lowLightPolicy.isLowLight
        let isLowLight = lowLightPolicy.ingest(luma: luma, at: timestamp)
        guard isLowLight != wasLowLight else { return }

        lowLightWarning = isLowLight ? "More light helps Tacit see your hand." : nil
        recomputeWarning()

        Task { [pipeline] in
            await pipeline?.setLowLight(isLowLight)
        }
    }

    // MARK: - Accessibility warning (spec §6, Task 20; wired in `init`, Task 21)

    private func recomputeAccessibilityWarning() {
        let trusted = AXIsProcessTrusted()
        if trusted != lastLoggedAccessibilityTrusted {
            lastLoggedAccessibilityTrusted = trusted
            TacitLog.engine.notice("AXIsProcessTrusted -> \(trusted, privacy: .public)")
        }
        accessibilityWarning = (enabledKeystrokeBindingExists && !trusted)
            ? "Keystroke actions need Accessibility"
            : nil
        recomputeWarning()
    }

    private func isRunning(_ state: CaptureState) -> Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Per-frame pipeline results

    /// Applies a `PipelineCore.Result`, unless `generation` (captured when this frame's
    /// `process(...)` call was *submitted*) no longer matches `pipelineGeneration` — meaning a
    /// reset happened while this frame was in flight, so its arbitration state is stale and must
    /// be dropped rather than published. See `pipelineGeneration`'s doc comment.
    private func apply(_ result: PipelineCore.Result, generation: Int, timestamp: TimeInterval) {
        guard generation == pipelineGeneration else { return }

        if let frame = result.frame {
            latestFrame = frame
            recorder.append(frame)
        } else {
            latestFrame = nil
        }

        if !arbitrationStatesMatch(lastArbitrationState, result.arbitrationState) {
            TacitLog.engine.notice("arbitration -> \(String(describing: result.arbitrationState), privacy: .public)")
        }
        lastArbitrationState = result.arbitrationState

        // Re-check the MainActor's own `isPreviewActive` (not just whatever this frame's
        // `PipelineCore` happened to compute) so a preview turned off *after* this frame was
        // already in flight can't resurrect a stale lit candidate — the same race the `didSet`
        // above already guards against on the "turn off" side.
        previewCandidate = isPreviewActive ? result.previewCandidate : nil

        if let event = result.event {
            lastEvent = event
            TacitLog.engine.notice("fired gesture=\(event.gesture.rawValue, privacy: .public)")
            pulseFired()
            handleFire(event)
        } else {
            recomputeGlyphState()
        }

        // Gesture debug view: zero cost while off (one branch, no allocation). `staticCandidate`
        // is `PipelineCore.Result`'s raw, pre-clutch-gating classifier reading — populated here
        // even while `disarmed`/`arming`, which is the whole point: a user tuning their hand/camera
        // needs to see what the classifier thinks BEFORE the clutch ever gates it. `lastEvent`/
        // `.timestamp` are read AFTER the fire handling above so a fire on THIS frame is already
        // reflected. See `GestureDebug.swift`.
        if isDebugViewEnabled {
            debugSnapshot = GestureDebugSnapshot(
                frame: result.frame,
                handDetected: result.frame != nil,
                staticCandidate: result.staticCandidate,
                arbitration: result.arbitrationState,
                lastFired: lastEvent?.gesture,
                lastFiredAt: lastEvent?.timestamp,
                isLowLight: lowLightPolicy.isLowLight,
                isAccessibilityTrusted: AXIsProcessTrusted(),
                timestamp: timestamp,
                requiresClutch: requiresClutch
            )
        }

        // M3 Task 9: hold-gesture lifecycle. Fed every frame with the fired event (if any — for
        // the v1 holdable set, [.indexPoint, .thumbsUp, .victory], that's always a plain static
        // fire, never a momentary one) and the raw static candidate, regardless of arbitration
        // state. A `.began` for a gesture NOT bound to `.holdKeystroke` is deliberately ignored by
        // `handleHoldEvent` — the normal fire path above already handled that fire completely; a
        // hold's own bookkeeping (`isHoldActive`) still tracks it purely so the window-extension
        // logic below keeps working for it too.
        if let holdEvent = holdTracker.ingest(fired: result.event, candidate: result.staticCandidate, at: timestamp) {
            isHoldActive = (holdEvent.phase == .began)
            handleHoldEvent(holdEvent)
        }

        if isHoldActive {
            if case .armed = result.arbitrationState {
                // Keep the command window from expiring out from under the hold — see
                // `ArbitrationEngine.extendWindow(at:)`'s doc comment. Fire-and-forget onto the
                // pipeline actor (same pattern as `setLowLight`/`setSensitivity` elsewhere in this
                // file); `extendWindow` itself is a no-op if arbitration is no longer armed by the
                // time this runs, so a benign race against a concurrent disarm is harmless.
                //
                // Clutch-optional setting: while `requiresClutch` is `false` the window is already
                // `.infinity` (see `ArbitrationEngine`'s clutch-off mode) and can never expire out
                // from under anything, so this no-ops entirely — no Task spawned, no per-frame
                // allocation, no actor hop for a call `ArbitrationEngine.extendWindow` would have
                // ignored anyway. Holds are unaffected either way: `isHoldActive` still tracks the
                // hold correctly, and `result.arbitrationState` stays `.armed` for the hold's whole
                // duration in clutch-off mode, so the `else` branch below (which ends the hold)
                // is simply never reached until the pose itself is released.
                if requiresClutch {
                    Task { [pipeline] in
                        await pipeline?.extendArbitrationWindow(at: timestamp)
                    }
                }
            } else {
                // M3 Task 9 ended-path: disarm / command-window expiry. Arbitration is no longer
                // `.armed` on a frame where a hold was still active — there's no window left to
                // extend, and no armed session left for an eventual key-up to make sense inside.
                // End the hold NOW rather than waiting for `handleCaptureStateChange`'s coarser
                // chokepoint (capture is still running here; that chokepoint would never fire).
                endActiveHoldIfNeeded()
            }
        }
    }

    /// Case-only equality for `ArbitrationState`, ignoring associated `progress`/`windowEndsAt`
    /// values (which tick every frame while arming/armed) — used solely to gate the diagnostic
    /// arbitration-transition log in `apply(_:generation:timestamp:)` on a genuine phase change,
    /// never a per-frame progress/window update.
    private func arbitrationStatesMatch(_ a: ArbitrationState, _ b: ArbitrationState) -> Bool {
        switch (a, b) {
        case (.disarmed, .disarmed), (.arming, .arming), (.armed, .armed):
            return true
        default:
            return false
        }
    }

    // MARK: - Hold-gesture lifecycle (M3 Task 9)

    /// Routes a `HoldTracker` phase transition to its dispatch/HUD side effects.
    private func handleHoldEvent(_ event: GestureHoldEvent) {
        switch event.phase {
        case .began: handleHoldBegan(event)
        case .ended: handleHoldEnded(event)
        }
    }

    /// A holdable gesture just began being held. Looks up its CURRENT binding: if it's enabled
    /// and bound to `.holdKeystroke`, posts the key-down and shows the HUD's persistent "holding"
    /// chip; if it's enabled and bound to `.toggleKeystroke` (2026-08-24 ring/pinky-tap-overlap
    /// ruling), fires the toggle exactly once via `handleToggleFire(gesture:chord:)` instead — see
    /// that branch below for why. Any other binding (disabled, unbound, or bound to a momentary
    /// action kind) is a complete no-op here — the gesture's normal fire already happened via
    /// `handleFire(_:)` in `apply(_:generation:timestamp:)`, and `activeHoldChord` staying `nil`
    /// is exactly what makes `handleHoldEnded(_:)` correctly do nothing when this same hold
    /// eventually ends.
    ///
    /// **Post-review fix (structural key ordering):** `postKeyDown` is called SYNCHRONOUSLY, on
    /// the main actor — deliberately NOT `Task.detached`, unlike `handleFire(_:)`'s dispatch of a
    /// full `TacitAction`. Those are different operations with different hazards: `handleFire(_:)`
    /// goes off-main because `ActionDispatcher.dispatch` can call into `.runShortcut`, which
    /// blocks the calling thread on `Process.waitUntilExit()` for as long as the Shortcut takes to
    /// run — THAT is what must never risk stalling the main actor. `postKeyDown`/`postKeyUp` here
    /// are just `CGEvent(...).post(tap:)`, a microseconds-scale, non-blocking OS call with no
    /// `waitUntilExit`-style hazard — there's no latency reason to detach it, and detaching it was
    /// actively WRONG: two independent `Task.detached` closures (one spawned here, one from
    /// `handleHoldEnded`) have NO ordering guarantee relative to each other from Swift's
    /// perspective, so a rapid hold→release→re-hold sequence — or a release racing
    /// `handleApplicationWillTerminate`'s own synchronous key-up at quit — could post the up
    /// before the down had even run: a key stuck down forever, exactly the failure mode this
    /// feature exists to make impossible. Calling `postKeyDown`/`postKeyUp` directly, synchronously,
    /// on the main actor makes the ordering STRUCTURAL instead of merely likely: MainActor
    /// serialization guarantees this call runs to completion before ANY other main-actor code —
    /// including a later `handleHoldEnded`'s `postKeyUp`, or `handleApplicationWillTerminate`'s —
    /// gets a turn, so down always happens before up, in every interleaving.
    private func handleHoldBegan(_ event: GestureHoldEvent) {
        let binding = mappingStore.binding(for: event.gesture)
        guard binding.enabled, let action = binding.action else { return }

        // 2026-08-24 ring/pinky-tap-overlap ruling: a HOLDABLE gesture bound to
        // `.toggleKeystroke` (e.g. victory, defaults revision 5) toggles exactly ONCE, right here
        // on the pose's onset — never from `handleFire(_:)`, which would otherwise re-fire the
        // toggle roughly every ~0.9s for as long as the pose is held (see `handleFire(_:)`'s
        // matching early-return guard for the full repeat-fire hazard) and flip the latch
        // on->off->on while the user simply holds the pose. Delegates to the SAME
        // `handleToggleFire(gesture:chord:)` a momentary toggle-bound gesture's plain fire uses,
        // so engage/release/swap, the Accessibility gate, and the HUD line all behave identically
        // either way. Deliberately does NOT set `activeHoldChord`/call `postKeyDown`/call
        // `hudController.showHold` — those are the `.holdKeystroke` hold-chip machinery below,
        // which a toggle has no use for: `handleToggleFire` already posted its own key event and
        // shows its own "<key> on/off" HUD line. Leaving `activeHoldChord` nil here is exactly
        // what makes `handleHoldEnded(_:)` correctly do nothing when this hold ends — the latch,
        // not the hold, owns the eventual release (releasing on a second toggle, or via any of
        // `releaseLatchIfNeeded()`'s other chokepoints), same mirror-image shape as `.holdKeystroke`'s
        // own Ruling 3 guard just below handles for a hold already owning an already-latched chord.
        if case .toggleKeystroke(let chord) = action {
            handleToggleFire(gesture: event.gesture, chord: chord)
            return
        }

        guard case .holdKeystroke(let chord) = action else { return }

        // Ruling 3: a hold of a chord that's already latched is a no-op — the key is down, and
        // leaving `activeHoldChord` nil makes the matching `.ended` a no-op too, so the latch
        // (not the hold) still owns the eventual key-up.
        guard !keyLatch.isLatched(chord) else { return }

        guard actionEnvironment.isAccessibilityTrusted() else {
            if isHUDEnabled {
                hudController.showError("Keystroke actions need Accessibility — grant it in the Library.")
            }
            return
        }

        activeHoldChord = chord
        _ = actionEnvironment.postKeyDown(chord)
        TacitLog.actions.notice("hold began: chord=\(chord.display, privacy: .public) down")
        if isHUDEnabled {
            // `HUDController.showHold` renders "<Gesture> → holding <label>" — deliberately the
            // bare key label (chord.display, "Fn" for keyCode 63 via `KeyChord.capNames`), NOT
            // `action.summary` (which is already "Hold ⌘Space"/"Hold Fn"): prefixing "holding "
            // onto THAT would double up into "holding Hold Fn". M3 Task 11 (fix pass): this used
            // to special-case keyCode 63 itself, the sibling of the one `TacitAction.summary` had
            // — both are gone now that `capNames` covers keyCode 63 directly.
            hudController.showHold(gesture: event.gesture, actionSummary: chord.display, frame: latestFrame)
        }
    }

    /// A hold just ended (pose lost, or forced via `endActiveHoldIfNeeded()`). Posts the paired
    /// key-up ONLY if a matching key-down was actually sent — see `releaseActiveHold()`. Always
    /// tells the HUD to end the hold chip (idempotent/harmless if nothing was showing).
    ///
    /// Synchronous, on the main actor — see `handleHoldBegan(_:)`'s doc comment for why this is
    /// safe (a non-blocking `CGEvent` post) and, post-review, why it's required: this must be
    /// ordered structurally after `handleHoldBegan`'s `postKeyDown`, which only MainActor
    /// serialization (not two independent detached Tasks racing each other) can guarantee.
    private func handleHoldEnded(_ event: GestureHoldEvent) {
        defer { hudController.endHold() }
        guard let chord = releaseActiveHold() else { return }
        _ = actionEnvironment.postKeyUp(chord)
        TacitLog.actions.notice("hold ended: chord=\(chord.display, privacy: .public) up")
    }

    /// Code review 2026-08-27, Finding 3, write half: persists `chord` into `UserDefaults` under
    /// `tacit.latchedChord` (JSON via `KeyChord`'s `Codable` conformance) so `TacitEngine.init`'s
    /// cold-start recovery can replay its key-up if this process dies before the matching release.
    /// Called from `handleToggleFire` immediately after each real `postKeyDown` for an
    /// `.engaged`/`.swapped` latch-on — as close to that post as possible, so the window between
    /// the actual key going down and a recovery record existing for it is as small as it can be.
    private func persistLatchedChord(_ chord: KeyChord) {
        guard let data = try? JSONEncoder().encode(chord) else { return }
        UserDefaults.standard.set(data, forKey: Self.latchedChordDefaultsKey)
    }

    /// Code review 2026-08-27, Finding 3, clear half of `persistLatchedChord(_:)` above — called
    /// at every site that sets `latchedChord` back to `nil`: `releaseLatchIfNeeded()`,
    /// `handleToggleFire`'s `.released` transition, and its two untrusted-undo branches (an engage
    /// computed but never actually posted, or a swap downgraded to a release because Accessibility
    /// was revoked mid-swap). Keeps the persisted record honest — without this half, an organic
    /// release would leave a stale chord behind for the next launch's cold-start recovery to post
    /// a harmless-but-needless key-up for.
    private func clearPersistedLatchedChord() {
        UserDefaults.standard.removeObject(forKey: Self.latchedChordDefaultsKey)
    }

    /// A fire of a gesture bound to `.toggleKeystroke`. Engages, releases, or swaps the latch and
    /// posts the matching key events synchronously (`.swapped` posts the old chord's up BEFORE the
    /// new chord's down, so at most one latched key is ever down). User-initiated, so it shows
    /// "<Gesture> → <key> on/off" (Ruling 4); the forced releases in `releaseLatchIfNeeded()` are
    /// silent.
    ///
    /// **Finding 3 (crash recovery):** every successful engage/swap-engage below calls
    /// `persistLatchedChord(_:)` right after its `postKeyDown`; every release path calls
    /// `clearPersistedLatchedChord()`. See both methods' doc comments for the full accounting.
    ///
    /// **Post-review fix (Accessibility gates engage only, never release):** the trust check used
    /// to run BEFORE `keyLatch.toggle(...)` was even called, so with a chord already latched (real
    /// key-down already delivered while trust was granted) and Accessibility later revoked, the
    /// user's second tap of the same gesture — their only in-gesture way to turn it back off — hit
    /// the guard and returned without ever calling `keyLatch.toggle`, leaving the target app's key
    /// genuinely stuck down with only the popover's "Release" row as an escape hatch. The fix
    /// computes the transition FIRST (pure, no side effects beyond `KeyLatch`'s own state), then
    /// branches: `.released` always posts the up and clears state — no trust check, matching
    /// `releaseLatchIfNeeded()`'s and `handleHoldEnded(_:)`'s unconditional-release convention.
    /// `.engaged` posts the down only if trusted; if untrusted, the just-computed engage is undone
    /// via `keyLatch.release()` (nothing was ever posted, so nothing to undo there) and the error
    /// shows instead. `.swapped` always posts the old chord's up first (release direction, ungated,
    /// same as `.released`); the new chord's down posts only if trusted, otherwise the swap is
    /// downgraded to a plain release — `keyLatch.release()` clears the just-engaged new chord so
    /// nothing stays latched, and the error shows in place of the "on" HUD.
    private func handleToggleFire(gesture: GestureID, chord: KeyChord) {
        // Ruling (Task 4 review): if a hold currently owns this chord, a toggle fire is a no-op —
        // the hold's own `.ended` will post the key-up; engaging the latch here would double-post
        // the key-down and leave the latch believing it owns a key it doesn't. By the hold/latch
        // mutual-exclusion invariant (`handleHoldBegan`'s `!keyLatch.isLatched(chord)` guard), a
        // chord already latched can never equal `activeHoldChord`, so this guard never blocks the
        // release or swap-release direction of `keyLatch.toggle` below — it only ever preempts a
        // fresh engage while a hold owns the chord. Release paths never consult this guard.
        guard activeHoldChord != chord else { return }

        let trusted = actionEnvironment.isAccessibilityTrusted()
        let summary: String
        switch keyLatch.toggle(gesture: gesture, chord: chord) {
        case .engaged(let engaged):
            guard trusted else {
                _ = keyLatch.release()
                latchedChord = keyLatch.active?.chord
                clearPersistedLatchedChord()
                if isHUDEnabled {
                    hudController.showError("Keystroke actions need Accessibility — grant it in the Library.")
                }
                return
            }
            _ = actionEnvironment.postKeyDown(engaged)
            persistLatchedChord(engaged)
            TacitLog.actions.notice("toggle engaged: chord=\(engaged.display, privacy: .public) down")
            summary = "\(engaged.display) on"
        case .released(let released):
            // Always post the up — no trust check (this is the fix): the release direction must
            // never be gated on Accessibility, or a chord latched while trusted could never be
            // turned back off once trust is revoked.
            _ = actionEnvironment.postKeyUp(released)
            clearPersistedLatchedChord()
            TacitLog.actions.notice("toggle released: chord=\(released.display, privacy: .public) up")
            summary = "\(released.display) off"
        case .swapped(let released, let engaged):
            // Old-chord up always posts first — release direction, ungated, same as `.released`.
            _ = actionEnvironment.postKeyUp(released)
            TacitLog.actions.notice("toggle swapped: chord=\(released.display, privacy: .public) up")
            guard trusted else {
                _ = keyLatch.release()
                latchedChord = keyLatch.active?.chord
                clearPersistedLatchedChord()
                if isHUDEnabled {
                    hudController.showError("Keystroke actions need Accessibility — grant it in the Library.")
                }
                return
            }
            _ = actionEnvironment.postKeyDown(engaged)
            persistLatchedChord(engaged)
            TacitLog.actions.notice("toggle swapped: chord=\(engaged.display, privacy: .public) down")
            summary = "\(engaged.display) on"
        }
        latchedChord = keyLatch.active?.chord
        if isHUDEnabled {
            hudController.show(gesture: gesture, actionSummary: summary, frame: latestFrame)
        }
    }

    /// The single chokepoint for every NON-toggle release of the latch. Posts the key-up
    /// synchronously if — and only if — a chord was actually latched; safe to call when nothing is.
    /// Also clears the Finding 3 crash-recovery record (`clearPersistedLatchedChord()`) in that
    /// same case, so a later relaunch doesn't replay a key-up for a chord that's already released.
    /// Silent by design (Ruling 4): the surface that caused it is the feedback.
    ///
    /// **Every place this is called, and why (the stuck-key audit for toggles):**
    ///  - `handleCaptureStateChange` — capture paused/interrupted/unavailable: master toggle off,
    ///    "Pause for an Hour", screen lock, display sleep, camera claimed elsewhere. No frames will
    ///    arrive to toggle it off, so it must end here.
    ///  - `handleApplicationWillTerminate` — app quit.
    ///  - the `mappingStore.$bindings` sink — the latched gesture was rebound, cleared, or disabled
    ///    in the Library (its binding is no longer `enabled` + `.toggleKeystroke(sameChord)`).
    ///  - `releaseLatch()` — the popover's "Release <key>" row.
    ///  - NOT on clutch disarm / command-window expiry (`apply(_:generation:timestamp:)`): the
    ///    latch exists precisely so the hand can rest while dictation continues (Ruling 2).
    ///  - NOT on `handleHoldEnded(_:)` for a HOLDABLE gesture bound to `.toggleKeystroke`
    ///    (2026-08-24 ring/pinky-tap-overlap ruling, e.g. `victory` releasing its pose): the
    ///    toggle fired once, via `handleToggleFire`, on the hold's `.began` — `activeHoldChord`
    ///    was deliberately never set for it (see `handleHoldBegan(_:)`'s toggle branch), so the
    ///    hold's `.ended` is a no-op and the latch stays engaged after the pose is released,
    ///    exactly like any other toggle; only a second toggle-fire (organic release, via this same
    ///    chokepoint's other callers, or the popover's "Release" row) turns it back off.
    ///  - NOT reached from `handleToggleFire` when a hold already owns the chord (Task 4 review
    ///    ruling): that guard returns before `keyLatch.toggle(...)` is ever called, so the latch
    ///    never believes it owns a key the hold is actually holding — the hold's own `.ended` is
    ///    what posts that key-up, via `releaseActiveHold()`, not this chokepoint.
    ///  - NOT how `handleToggleFire` itself releases the latch, in TWO different ways, neither of
    ///    which goes through this chokepoint:
    ///    1. **The organic "tap again to turn it off" release** (`.released`/`.swapped`'s release
    ///       half): posts `postKeyUp` directly and inline, unconditionally — no Accessibility
    ///       check (post-review fix: release must never be gated on trust, or a chord latched
    ///       while trusted could never be turned back off once trust is revoked). This path
    ///       always has a real key-up to post, so it is deliberately NOT silent (Ruling 4) —
    ///       it shows "<key> off" like any other user-initiated toggle.
    ///    2. **The untrusted-engage / untrusted-swap-downgrade undo** (`.engaged`/`.swapped`'s
    ///       engage half, when `isAccessibilityTrusted()` is false): calls `keyLatch.release()`
    ///       directly to discard the just-computed engage — no `postKeyDown` was ever sent for
    ///       it, so there is nothing to post an up for either; only the error HUD shows.
    private func releaseLatchIfNeeded() {
        guard let chord = keyLatch.release() else { return }
        latchedChord = nil
        clearPersistedLatchedChord()
        _ = actionEnvironment.postKeyUp(chord)
        TacitLog.actions.notice("latch force-released: chord=\(chord.display, privacy: .public) up")
    }

    /// Popover "Release <key>" row (Task 5). User-initiated, so it's the one forced release that
    /// does announce itself — using the latched gesture's own chip, like a second tap would.
    func releaseLatch() {
        guard let active = keyLatch.active else { return }
        releaseLatchIfNeeded()
        if isHUDEnabled {
            hudController.show(gesture: active.gesture, actionSummary: "\(active.chord.display) off", frame: latestFrame)
        }
    }

    /// Shared by `handleHoldEnded(_:)` and `handleApplicationWillTerminate()` (post-review MINOR
    /// fix — the two previously duplicated this exact clear-and-return inline). Clears this hold's
    /// key-release bookkeeping (`isHoldActive`, `activeHoldChord`) and returns the `KeyChord` a
    /// caller must post a key-up for — `nil` if no key-down was ever actually sent for the hold
    /// that just ended (not bound to `.holdKeystroke`, Accessibility wasn't trusted, etc., in
    /// which case there is nothing to release). Both `handleHoldEnded(_:)` and
    /// `handleApplicationWillTerminate()` post the resulting key-up the same way — synchronously,
    /// on the main actor (see `handleHoldBegan(_:)`'s doc comment for why that's required) — so
    /// only the ENTRY GATE differs between the two callers: `handleHoldEnded(_:)` is reached via
    /// the organic pose-loss/forced-reset paths above, while `handleApplicationWillTerminate()`
    /// gates on its own `holdTracker.reset()` call instead of going through
    /// `endActiveHoldIfNeeded()`. This helper is the bookkeeping both share.
    private func releaseActiveHold() -> KeyChord? {
        isHoldActive = false
        defer { activeHoldChord = nil }
        return activeHoldChord
    }

    /// The single chokepoint every non-pose-based hold-ended path routes through (brief: "a
    /// stuck-down Fn key is the failure mode to make impossible"). Resets `holdTracker`
    /// unconditionally; if a hold was actually active, ends it exactly like an organic pose-loss
    /// `.ended` would (posts the paired key-up, synchronously, only if a real key-down was sent,
    /// and dismisses the HUD's hold chip). Safe to call when no hold is active — a no-op.
    ///
    /// **Every place this is called, and why (the stuck-key audit):**
    ///  - `apply(_:generation:timestamp:)` — disarm / command-window expiry: any frame where
    ///    `result.arbitrationState` is no longer `.armed` while a hold was active.
    ///  - `handleCaptureStateChange` — capture pause/unavailable, PLUS screen lock, display sleep,
    ///    and the `isEnabled` master toggle going off, since all three of those pause capture
    ///    (`pauseIfRunning`/`handleEnabledChange`) and land here as the same state transition; this
    ///    is also the only place that can still act once frames stop arriving entirely.
    ///  - `handleApplicationWillTerminate` — app quit — calls `releaseActiveHold()` directly
    ///    rather than through this method (it needs its own `holdTracker.reset()` as the gate for
    ///    whether to act at all); see that method's doc comment.
    ///  - Pose loss itself (the organic, expected end of a hold) does NOT go through this method —
    ///    it's handled directly by `holdTracker.ingest`'s own missing-frame count inside
    ///    `apply(_:generation:timestamp:)`, which calls `handleHoldEvent(_:)`.
    private func endActiveHoldIfNeeded() {
        isHoldActive = false
        guard let event = holdTracker.reset() else { return }
        handleHoldEnded(event)
    }

    /// App-quit ended-path (brief: "applicationWillTerminate via NSApplication notification").
    /// Posts the final key-up SYNCHRONOUSLY (always was, and — post-review — so does every other
    /// hold-ended path now; see `handleHoldBegan(_:)`'s doc comment for why synchronous, main-actor
    /// posting is safe and, in fact, required for correct ordering everywhere holds post keys).
    /// This remains best-effort in ONE specific sense unrelated to that fix: macOS doesn't
    /// guarantee this notification fires at all (e.g. a forced quit/SIGKILL skips it entirely) — a
    /// real stuck key from that class of exit is a known, documented limitation outside this
    /// method's control, not something any user-space code can prevent from happening in the
    /// moment. Code review 2026-08-27, Finding 3, gives the `.toggleKeystroke` half of that a
    /// recovery path anyway, on the NEXT launch rather than at this one's exit: `TacitEngine.init`
    /// replays a persisted latch's key-up unconditionally, before anything else, independent of
    /// whether this notification ever fired. A stuck `.holdKeystroke` hold has no equivalent —
    /// the review marks that lower priority, since a hold's window is seconds where a latch's is
    /// unbounded — so `activeHoldChord` is still only ever in-memory.
    private func handleApplicationWillTerminate() {
        releaseLatchIfNeeded()
        guard holdTracker.reset() != nil else { return }
        defer { hudController.endHold() }
        guard let chord = releaseActiveHold() else { return }
        _ = actionEnvironment.postKeyUp(chord)
    }

    // MARK: - Closing the loop: gesture event → dispatched action → HUD (Task 21)

    /// Looks up `event.gesture`'s binding and, if it's enabled and bound to an action, dispatches
    /// it and shows the resulting HUD feedback. Reserved gestures (`.looseFist`/`.openPalm`),
    /// unbound gestures (`action == nil`), and disabled bindings all no-op here — no dispatch, no
    /// HUD — matching the brief exactly; the glyph's fire pulse above already happened
    /// unconditionally regardless of binding state.
    private func handleFire(_ event: GestureEvent) {
        let binding = mappingStore.binding(for: event.gesture)
        guard binding.enabled, let action = binding.action else {
            TacitLog.engine.notice(
                "handleFire gesture=\(event.gesture.rawValue, privacy: .public) returning early: binding disabled or no action (enabled=\(binding.enabled, privacy: .public))"
            )
            return
        }

        // 2026-08-24 ring/pinky-tap-overlap ruling: a `.toggleKeystroke` binding on a HOLDABLE
        // gesture (`Self.holdableGestures` — e.g. `victory`, defaults revision 5) must never be
        // dispatched from here, for the exact same repeat-fire reason as the `.holdKeystroke`
        // guard just below: a fired event re-arrives roughly every ~0.9s while the pose keeps
        // being held (armed re-debounce + cooldown — see that guard's doc comment for the full
        // mechanism), so toggling on every repeat fire would flip the latch on->off->on for as
        // long as the user simply holds the pose, instead of toggling once on the pose's onset.
        // `handleHoldBegan(_:)` owns firing the toggle exactly once, via the SAME
        // `handleToggleFire(gesture:chord:)` this branch below calls for a momentary (non-holdable)
        // toggle-bound gesture — see that method's toggle branch for the full story.
        if case .toggleKeystroke = action, Self.holdableGestures.contains(event.gesture) {
            TacitLog.engine.notice(
                "handleFire gesture=\(event.gesture.rawValue, privacy: .public) returning early: holdable gesture owns .toggleKeystroke lifecycle via HoldTracker"
            )
            return
        }

        // Workhorse-remap plan, Task 4: `.toggleKeystroke` is engine-owned exactly like
        // `.holdKeystroke` — posted synchronously on the main actor (structural down/up ordering,
        // see `handleHoldBegan(_:)`'s doc comment), never through `ActionDispatcher.dispatch`'s
        // detached full-press fallback, and skipping `applyDispatchOutcome`'s first-fire
        // bookkeeping (the toggle's own HUD line below is the feedback). A HOLDABLE gesture bound
        // to `.toggleKeystroke` never reaches this branch — the guard just above already returned
        // for it — so this only ever handles momentary gestures (taps, swipes).
        if case .toggleKeystroke(let chord) = action {
            TacitLog.engine.notice(
                "handleFire gesture=\(event.gesture.rawValue, privacy: .public) routing to toggle branch: chord=\(chord.display, privacy: .public)"
            )
            handleToggleFire(gesture: event.gesture, chord: chord)
            return
        }

        // Final-review finding F1 (CRITICAL): a `.holdKeystroke` binding on a HOLDABLE gesture
        // (`Self.holdableGestures`) must never be dispatched from here. `apply(_:generation:
        // timestamp:)` feeds this SAME fired event into `holdTracker.ingest` on this SAME frame,
        // and `HoldTracker.ingest` begins a hold precisely when a holdable gesture just fired AND
        // its candidate still names that gesture on this same frame — which a static pose fire
        // always satisfies (a static fire only happens because the pose IS currently classifying,
        // so `.began` is guaranteed on this very frame; see `HoldTracker.ingest`'s doc comment).
        // `handleHoldBegan(_:)` then posts the key-down itself, synchronously, and
        // `handleHoldEnded(_:)` posts the matching key-up when the pose is released — the hold
        // path owns this binding's ENTIRE down/up lifecycle. Dispatching it again here would race
        // that synchronous key-down with a detached full press-and-release, AND — because a fired
        // event re-arrives roughly every ~0.9s while the pose keeps being held (armed
        // re-debounce + cooldown) — silently re-post a full key press every ~0.9s for the rest of
        // the hold. Returning here before the `Task.detached` dispatch also skips
        // `applyDispatchOutcome`'s celebratory-first-fire bookkeeping and HUD `.show` entirely —
        // correctly: the hold's own HUD chip (`handleHoldBegan(_:)`'s `hudController.showHold`) is
        // already the feedback for this fire. The glyph's `.fired` pulse (`pulseFired()`, called
        // unconditionally in `apply(_:generation:timestamp:)` before this method runs) still
        // happens on every repeat fire regardless — that's driven by the pipeline path above this
        // method, not by anything below, so this guard can't reach it; harmless and acceptable.
        //
        // Momentary gestures bound to `.holdKeystroke` (never in `holdableGestures`, since they
        // can't produce a `HoldTracker` began/ended pair at all) are NOT covered by this guard —
        // they keep falling through to `ActionDispatcher.dispatch`'s `.holdKeystroke` fallback,
        // which performs the full down-then-up press documented on that case.
        if case .holdKeystroke = action, Self.holdableGestures.contains(event.gesture) {
            TacitLog.engine.notice(
                "handleFire gesture=\(event.gesture.rawValue, privacy: .public) returning early: holdable gesture owns .holdKeystroke lifecycle via HoldTracker"
            )
            return
        }

        // Code review 2026-08-27, Finding 5: dispatch splits by ACTION KIND below because the two
        // branches guard against two DIFFERENT hazards, not one. The comment this replaced
        // asserted "never on the main actor" as a single blanket rule for `ActionDispatcher.
        // dispatch(_:)` — that was the wrong invariant, and finding 5 is exactly the bug that
        // followed from it (see this method's earlier guards' doc comments, and
        // `handleHoldBegan(_:)`'s, for the ordering argument this repeats).
        //
        // `.keystroke`, plus `.holdKeystroke`/`.toggleKeystroke` reaching `dispatch(_:)`'s
        // momentary full-press fallback (a holdable/latchable gesture's own hold/toggle lifecycle
        // already returned above, before this point, so only non-holdable, non-latched gestures'
        // bindings reach here for these two cases) dispatch SYNCHRONOUSLY, on the main actor —
        // exactly like `handleHoldBegan(_:)`'s `postKeyDown` and `handleHoldEnded(_:)`'s
        // `postKeyUp`. The reason is ORDERING, not blocking, same as those two:
        // `postKeystroke`/`postKeyDown`/`postKeyUp` are all microseconds-scale, non-blocking
        // `CGEvent(...).post(tap:)` calls (see `handleHoldBegan(_:)`'s doc comment for the full
        // argument), so there was never a latency reason to detach them — but two gestures with
        // independent per-gesture cooldowns (e.g. `thumbSwipeBackward`/⌘Z and
        // `thumbSwipeForward`/⇧⌘Z, both enabled factory defaults — `MappingStore.swift:435-440`)
        // can fire on consecutive ~66ms frames, and two independent `Task.detached` closures have
        // NO ordering guarantee relative to each other from Swift's perspective — the target app
        // could receive redo before undo. MainActor serialization is what makes fire order equal
        // delivery order, structurally, the same way it already does for a hold's down/up pair.
        //
        // `.launchApp`, `.openURL`, `.runShortcut`, `.focusTextInput`, and `.switchApp` stay on
        // `Task.detached`, off the main actor. For three of these the hazard really is blocking:
        // `.runShortcut` blocks on `Process.waitUntilExit()` (see
        // `LiveActionEnvironment.runShortcut`'s doc comment), `.focusTextInput` walks another
        // app's Accessibility tree (see `LiveActionEnvironment.focusTextInput`'s doc comment), and
        // `.switchApp` blocks on `DispatchQueue.main.sync` (see `LiveActionEnvironment.switchApp`'s
        // doc comment) — Finding 4's list. `.launchApp`/`.openURL` aren't independently blocking
        // today, but nothing about their ordering needs the main-actor guarantee the keystroke
        // branch above depends on either, so they stay grouped with the rest here; Finding 4's
        // task (e) is where this detached bucket gets its blocking calls fixed, not rebalanced by
        // kind. `actionDispatcher` (a `Sendable` struct of `@Sendable` closures) and
        // `action`/`gesture`/`frame` (all `Sendable` value types) are captured into the
        // `Task.detached` below that runs off any actor; only the resulting UI update hops back to
        // the main actor via `MainActor.run`.
        let gesture = event.gesture
        let frame = latestFrame

        switch action {
        case .keystroke, .holdKeystroke, .toggleKeystroke:
            let outcome = actionDispatcher.dispatch(action)
            switch outcome {
            case .performed:
                TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> performed")
            case .needsAccessibility:
                TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> needsAccessibility")
            case .failed(let message):
                TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> failed(\(message, privacy: .public))")
            }
            applyDispatchOutcome(outcome, gesture: gesture, action: action, frame: frame)

        case .launchApp, .openURL, .runShortcut, .focusTextInput, .switchApp:
            let dispatcher = actionDispatcher
            Task.detached { [weak self] in
                let outcome = dispatcher.dispatch(action)
                switch outcome {
                case .performed:
                    TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> performed")
                case .needsAccessibility:
                    TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> needsAccessibility")
                case .failed(let message):
                    TacitLog.actions.notice("dispatch gesture=\(gesture.rawValue, privacy: .public) -> failed(\(message, privacy: .public))")
                }
                await MainActor.run {
                    self?.applyDispatchOutcome(outcome, gesture: gesture, action: action, frame: frame)
                }
            }
        }
    }

    /// The main-actor-side half of `handleFire(_:)`, run once `actionDispatcher.dispatch` returns
    /// — directly, for the synchronous keystroke-shaped branch, or via `MainActor.run` from the
    /// `Task.detached` branch. Either way this method itself always runs on the main actor.
    private func applyDispatchOutcome(
        _ outcome: DispatchOutcome, gesture: GestureID, action: TacitAction, frame: LandmarkFrame?
    ) {
        switch outcome {
        case .performed:
            // Task 21 controller ruling (R4): the FIRST-EVER successful mapped-gesture fire (and
            // only that one) asks the HUD for the grander `celebratory` draw-on; every subsequent
            // fire uses the standard motion. The flag is set unconditionally the first time
            // through, regardless of what happens to `celebratory` below — a fire can only ever
            // be "the first" once. This bookkeeping runs even with the HUD disabled, so re-enabling
            // it later doesn't retroactively "un-fire" the celebration.
            let celebratory = !UserDefaults.standard.bool(forKey: Self.firstFireCelebratedKey)
            if celebratory {
                UserDefaults.standard.set(true, forKey: Self.firstFireCelebratedKey)
            }
            // Finding I1: `isHUDEnabled` gates confirmation UI only — the glyph pulse that already
            // ran in `apply(_:generation:)` (`pulseFired()`) is unaffected, matching spec §4's "keep
            // glyph feedback" while letting the HUD itself be turned off.
            guard isHUDEnabled else { return }
            hudController.show(gesture: gesture, actionSummary: action.summary, frame: frame, celebratory: celebratory)
        case .needsAccessibility:
            guard isHUDEnabled else { return }
            hudController.showError("Keystroke actions need Accessibility — grant it in the Library.")
        case .failed(let message):
            guard isHUDEnabled else { return }
            hudController.showError(message)
        }
    }

    // MARK: - glyphState derivation

    private func recomputeGlyphState() {
        // A pending fire pulse (see `pulseFired`) owns `glyphState` until it restores it itself;
        // don't stomp on it here.
        guard fireResetTask == nil else { return }
        glyphState = restingGlyphState()
    }

    private func restingGlyphState() -> GlyphState {
        guard isEnabled else { return .paused }
        switch capture.state {
        case .paused, .unavailable:
            return .paused
        case .running:
            break
        }
        switch lastArbitrationState {
        case .disarmed, .arming:
            return .watching
        case .armed:
            // Clutch-optional setting: while `requiresClutch` is `false`, arbitration is ALWAYS
            // reported `.armed` (see `ArbitrationEngine`'s clutch-off mode) — showing the accent
            // continuously would defeat the point of "one accent only for armed/fired" (spec §4),
            // since there'd be no distinct resting state left to contrast it against. Only the
            // transient `.fired` pulse (`pulseFired()`, unconditional) still shows the accent;
            // resting reads as the same open-hand `.watching` glyph as the clutch-on disarmed
            // state.
            return requiresClutch ? .armed : .watching
        }
    }

    /// Shows `.fired` for `TacitMotion.armedPulseDuration`, then restores whatever the resting
    /// state has become by then (glyph state, not necessarily what it was before firing — e.g. a
    /// fire that also happens to re-open the command window still reads `.armed` afterward).
    private func pulseFired() {
        fireResetTask?.cancel()
        glyphState = .fired
        fireResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TacitMotion.armedPulseDuration))
            guard !Task.isCancelled, let self else { return }
            self.fireResetTask = nil
            self.recomputeGlyphState()
        }
    }
}

/// Confines the non-thread-safe `TacitCore` pipeline (Vision detection → static-pose classification
/// → arbitration) to its own private executor.
///
/// Declared as a plain (non-`@MainActor`) `actor` rather than a `@MainActor` type or a locked
/// class: calling one of its `async` methods from anywhere — including the main actor — hops
/// execution onto this actor's own executor for the call's duration, guaranteeing
/// `HandPoseDetector.detect`'s synchronous Vision inference never runs on the main thread. Being an
/// `actor`, it's automatically `Sendable`, and its stored `ArbitrationEngine` (itself not
/// thread-safe) is safe precisely because nothing outside this actor's isolated methods ever
/// touches it — the "confine to one executor" contract `ArbitrationEngine` requires.
private actor PipelineCore {
    private let detector = HandPoseDetector()
    private let classifier = StaticPoseClassifier()
    private let arbitration = ArbitrationEngine()
    /// M3 Task 6: the un-adjusted tuning `arbitration` was constructed with — kept here (not just
    /// inline in `ArbitrationEngine()`'s default) so `recomputeTuning()` below always has the true
    /// baseline to adjust FROM, regardless of how many times low light has flipped on/off since.
    /// Without this, feeding an already-adjusted tuning back into `LowLightPolicy.adjusted` on a
    /// second "low light" flip would double-raise `enterConfidence`/`stayConfidence` instead of
    /// idempotently reaching the same adjusted values every time.
    private let baseArbitrationTuning = ArbitrationTuning()
    /// M3 Task 7: the Settings tab's persisted sensitivity trim, defaulting to `.standard` (the
    /// untouched baseline) until `setSensitivity(_:)` below is told otherwise. Kept here (not just
    /// applied once and discarded) for the same reason `baseArbitrationTuning` is kept — see
    /// `recomputeTuning()`'s doc comment for why BOTH this and the low-light flag have to survive
    /// independently between recomputes.
    private var currentSensitivity: SensitivityTrim = .standard
    /// M3 Task 7: mirrors the most recent `setLowLight(_:)` argument so `recomputeTuning()` can
    /// re-derive the fully composed tuning from `baseArbitrationTuning` on EITHER a sensitivity
    /// change or a low-light flip, without needing the caller to re-supply the other half.
    private var isLowLight = false
    /// Clutch-optional setting (2026-08-24): mirrors the most recent `setClutchRequired(_:)`
    /// argument, folded into `recomputeTuning()`'s composed tuning the same way `isLowLight` is —
    /// see that method's doc comment for the composition order. Defaults to `true` (matching
    /// `ArbitrationTuning.requiresClutch`'s own default) purely as this actor's construction-time
    /// value; `TacitEngine.start()` applies the real persisted value (default `false`) once,
    /// exactly like it already does for `currentSensitivity`.
    private var currentRequiresClutch = true

    /// Task 21 controller ruling (R2): the PRODUCTION tap/swipe detectors, run on every frame
    /// regardless of arbitration state — their own internal tracking (an in-progress pinch or
    /// swipe) has to keep evolving through disarmed/arming frames so it's already primed the
    /// instant the clutch arms. SEPARATE instances from `previewTapDetector`/`previewSwipeDetector`
    /// below, so a card-detail preview session's tracking state can never leak into (or be leaked
    /// into by) production recognition.
    private var tapDetector = PinchTapDetector()
    private var swipeDetector = ThumbSwipeDetector()
    /// M3 Task 5: the four new dynamic-layer detectors, wired in at the same "every frame,
    /// unconditionally" level as `tapDetector`/`swipeDetector` above — see `process(_:_:)`'s doc
    /// comment for the full momentary precedence order they participate in. `PinchDragDetector`
    /// has NO production instance here: per plan ruling 2, `.pinchDrag` ships recognition +
    /// preview only in v1 (stays unbindable; true continuous 2D drag is a later milestone), so it
    /// must never feed `arbitration.ingestPreDebounced`/production dispatch — only the PREVIEW
    /// instance below exists, and only the preview candidate ever reads it.
    private var handSwipeDetector = HandSwipeDetector()
    private var fistToOpenDetector = FistToOpenDetector()
    private var wristRotateDetector = WristRotateDetector()
    private var twoFingerScrollDetector = TwoFingerScrollDetector()
    /// 2026-08-24 ruling ("whole-hand swipes aren't being detected"): the app-switch job's
    /// replacement — an open-palm tilt left/right — wired in at the same "every frame,
    /// unconditionally" level as the rest, ahead of `handSwipeDetector` in the momentary
    /// precedence chain below (see `process(_:_:)`'s doc comment).
    private var palmTiltDetector = PalmTiltDetector()

    /// Task 19's perform-to-preview mode: `false` unless a `CardDetailView` preview strip is
    /// currently mounted (see `TacitEngine.isPreviewActive`). `previewTapDetector` /
    /// `previewSwipeDetector` (and the M3 Task 5 additions below) are SEPARATE instances from the
    /// production ones above so preview state can never cross into or out of the arbitration path.
    private var previewActive = false
    private var previewTapDetector = PinchTapDetector()
    private var previewSwipeDetector = ThumbSwipeDetector()
    /// M3 Task 5: preview-only counterparts of the four production detectors above, PLUS
    /// `PinchDragDetector` — which, per plan ruling 2, exists ONLY here. `previewPinchDragDetector`
    /// is never read anywhere but the preview branch of `process(_:_:)`, and its output never
    /// reaches `arbitration` in any form.
    private var previewHandSwipeDetector = HandSwipeDetector()
    private var previewFistToOpenDetector = FistToOpenDetector()
    private var previewWristRotateDetector = WristRotateDetector()
    private var previewTwoFingerScrollDetector = TwoFingerScrollDetector()
    private var previewPinchDragDetector = PinchDragDetector()
    /// Preview counterpart of `palmTiltDetector` above.
    private var previewPalmTiltDetector = PalmTiltDetector()
    /// Fix (post-Task-19 review): tap/swipe detectors only fire on the ONE frame a tap releases or
    /// a swipe's travel threshold is crossed — at ~15Hz that's a ~66ms candidate, invisible as a
    /// "light up." This latches that momentary candidate so `previewCandidate` keeps reporting it
    /// for `previewLatchDuration` after the firing frame, giving the strip something actually
    /// visible to show. Expiry is driven entirely by `frame.timestamp` (never `Date()`), matching
    /// every other time-based decision in this pipeline.
    private var previewLatch: (candidate: GestureCandidate, expiresAt: TimeInterval)?
    private static let previewLatchDuration: TimeInterval = 0.6

    struct Result: Sendable {
        var frame: LandmarkFrame?
        var arbitrationState: ArbitrationState
        var event: GestureEvent?
        /// Raw candidate for Task 19's preview strip, bypassing arbitration entirely — nil unless
        /// `previewActive`. See `process(pixelBuffer:timestamp:)`'s doc comment for precedence.
        var previewCandidate: GestureCandidate?
        /// M3 Task 9: the raw static-pose candidate this frame — i.e. `classifier.classify`'s
        /// result, the SAME value fed into `arbitration.ingest` above, BEFORE any clutch-gating —
        /// added so `TacitEngine` can feed its `HoldTracker` the pose that's currently classifying
        /// regardless of arbitration state (a hold's persistence check cares whether the pose is
        /// still there, not whether the clutch happens to be armed). `nil` on any frame with no
        /// hand, or where the classifier didn't match any static pose.
        var staticCandidate: GestureCandidate?
    }

    /// Runs one captured frame through detection → classification → arbitration. Callers are
    /// expected (by `TacitEngine.start()`'s single consuming `Task`) to await each call to
    /// completion before issuing the next, so this never actually executes concurrently with
    /// itself — but even if it did, actor isolation would serialize it safely.
    ///
    /// Task 21 controller ruling (R2), production event precedence: `tapDetector`/`swipeDetector`
    /// (and, as of M3 Task 5, `handSwipeDetector`/`fistToOpenDetector`/`wristRotateDetector`/
    /// `twoFingerScrollDetector`) run on EVERY frame (unconditionally, not gated on
    /// `previewActive` or on arbitration state — each detector's own tracking has to keep evolving
    /// through disarmed/arming frames). The static candidate is ingested into `arbitration.ingest`
    /// FIRST, exactly as before — the clutch/disarm path must see every frame regardless of what a
    /// momentary detector does. THEN a momentary candidate goes through the separate
    /// `arbitration.ingestPreDebounced` entry point (see that method's doc comment — momentary
    /// candidates are already self-debounced in time by their own detectors and could never
    /// satisfy `ingest`'s 3-frame debounce).
    ///
    /// **Momentary precedence, first non-nil wins (identical order in production, preview, the
    /// `PipelineIntegrationTests` `Harness`, and `NegativeSuiteTests.replayThroughFullChain` — keep
    /// all four in lockstep):** tap > thumbSwipe > palmTilt > handSwipe > fistToOpen > rotate tick >
    /// scroll tick. `palmTiltDetector` sits ahead of `handSwipeDetector` (and therefore ahead of the
    /// static `.openPalm` candidate too — see below) but behind tap/thumbSwipe, per the 2026-08-24
    /// ruling that replaced the hand-swipe app-switch gestures with a palm tilt. This is a plain
    /// `??` chain, so — same as the pre-M3 tap/swipe pair — a detector later
    /// in the chain is simply never `ingest`ed on a frame where an earlier one already fired;
    /// that's an accepted, established trade (a fire is a single frame, not an ongoing state) not
    /// a new one introduced here. If a momentary candidate and the static debounce path BOTH
    /// return an event on the same frame, the momentary one wins: it's what this function returns,
    /// and the static event is ledger-dropped — `ingest`'s own bookkeeping (cooldown, window
    /// extension) for that static fire already happened above and is never undone, only which
    /// `GestureEvent` is reported to `TacitEngine` differs. Static classifier ingest ordering
    /// itself (clutch first, then momentary via `ingestPreDebounced`) is unchanged from before M3.
    ///
    /// When `previewActive`, this ALSO runs the frame through preview-scoped counterparts of all
    /// six momentary detectors above, entirely independent of (and never feeding into)
    /// `arbitration` — nothing below this point ever reads back into `arbitration` or the
    /// production `candidate`/`event` values. The preview chain appends ONE more detector,
    /// `previewPinchDragDetector`, LAST in precedence — `.pinchDrag` is preview-only (plan ruling
    /// 2: unbindable in v1) and must never be reachable from the production chain at all, so it
    /// has no production counterpart above and is added only here.
    ///
    /// `previewCandidate` precedence: a freshly-firing momentary candidate this frame > an
    /// unexpired latch from an earlier firing > the frame's own static `candidate`. A live static
    /// pose (held) is never masked by a stale (expired) latch — the latch is dropped the first
    /// frame it expires and the static candidate takes over immediately.
    ///
    /// A frame with no detected hand (`frame == nil`, e.g. a brief occlusion or a relaxed hand
    /// dropping out of tracking) must NOT bypass the latch: the visible "lit" expression has to
    /// match the latch's own data lifetime, not the presence of a hand this particular frame. Such
    /// a frame still carries a real capture timestamp (`timestamp`, the same value `arbitration`
    /// already receives via `ingest(candidate, at: timestamp)` even when `candidate` is nil), so the
    /// latch is checked against that instead of `frame.timestamp` when there's no frame to read one
    /// from.
    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async -> Result {
        let frames = await detector.detect(in: pixelBuffer, timestamp: timestamp)
        let frame = frames.first
        let candidate = frame.flatMap(classifier.classify)
        let staticEvent = arbitration.ingest(candidate, at: timestamp)

        let momentary = frame.flatMap {
            tapDetector.ingest($0)
                ?? swipeDetector.ingest($0)
                ?? palmTiltDetector.ingest($0)
                ?? handSwipeDetector.ingest($0)
                ?? fistToOpenDetector.ingest($0)
                ?? wristRotateDetector.ingest($0)
                ?? twoFingerScrollDetector.ingest($0)
        }
        let preDebouncedEvent = momentary.flatMap { arbitration.ingestPreDebounced($0, at: timestamp) }
        let event = preDebouncedEvent ?? staticEvent

        var previewCandidate: GestureCandidate?
        if previewActive {
            if let frame {
                let momentary = previewTapDetector.ingest(frame)
                    ?? previewSwipeDetector.ingest(frame)
                    ?? previewPalmTiltDetector.ingest(frame)
                    ?? previewHandSwipeDetector.ingest(frame)
                    ?? previewFistToOpenDetector.ingest(frame)
                    ?? previewWristRotateDetector.ingest(frame)
                    ?? previewTwoFingerScrollDetector.ingest(frame)
                    ?? previewPinchDragDetector.ingest(frame)
                if let momentary {
                    previewLatch = (candidate: momentary, expiresAt: frame.timestamp + Self.previewLatchDuration)
                    previewCandidate = momentary
                } else if let latch = previewLatch, frame.timestamp < latch.expiresAt {
                    previewCandidate = latch.candidate
                } else {
                    previewLatch = nil
                    previewCandidate = candidate
                }
            } else if let latch = previewLatch, timestamp < latch.expiresAt {
                // No hand detected this frame: still honor an unexpired latch (using the frame
                // callback's own timestamp, since there's no `LandmarkFrame` to read one from) so a
                // brief occlusion/relax mid-window doesn't flicker the lit card off and back on.
                previewCandidate = latch.candidate
            } else {
                previewLatch = nil
            }
        }

        return Result(
            frame: frame,
            arbitrationState: arbitration.state,
            event: event,
            previewCandidate: previewCandidate,
            staticCandidate: candidate
        )
    }

    /// Returns arbitration to `.disarmed` — called when capture stops, so a later resume doesn't
    /// briefly show stale progress from before the pause.
    func reset() {
        arbitration.reset()
    }

    /// M3 Task 9: forwards to `ArbitrationEngine.extendWindow(at:)`, called by `TacitEngine` once
    /// per frame while its `HoldTracker` reports a hold is active — see that method's doc comment.
    /// An actor method (rather than exposing `arbitration` itself) purely to keep `arbitration`
    /// confined to this actor's executor, same as every other mutation here.
    func extendArbitrationWindow(at now: TimeInterval) {
        arbitration.extendWindow(at: now)
    }

    /// M3 Task 6: called by `TacitEngine` on every low-light hysteresis FLIP (not on every luma
    /// sample — see `TacitEngine.handleLuma(_:at:)`) to swap `arbitration`'s tuning to account for
    /// the new low-light state, composed on top of whatever sensitivity trim is currently active.
    ///
    /// This is an actor-isolated method specifically so the swap can never race a concurrently
    /// in-flight `process(pixelBuffer:timestamp:)` call: `process` suspends at `await
    /// detector.detect(...)`, and PipelineCore being an `actor` means that suspension is the only
    /// point another call into this actor — including this one — can run; `recomputeTuning()`
    /// itself has no suspension point, so once it starts running it completes atomically before
    /// the next queued call (whether that's the rest of a paused `process`, or another
    /// `setLowLight`/`setSensitivity`) gets a turn. `ArbitrationEngine.setTuning` swaps only the
    /// tuning field in place — `state`, the arming clock, the in-progress debounce, and every
    /// gesture's cooldown ledger are untouched — so a flip never disarms the user's clutch or
    /// clears a cooldown that was already ticking.
    ///
    /// Idempotent: always recomputes from the untouched `baseArbitrationTuning`, so calling this
    /// twice with the same `on` re-applies the identical tuning rather than compounding an
    /// adjustment.
    func setLowLight(_ on: Bool) {
        isLowLight = on
        recomputeTuning()
    }

    /// M3 Task 7: called by `TacitEngine` whenever the Settings tab's sensitivity picker changes
    /// (`"tacit.sensitivity"`). Composed the same way `setLowLight` is: recomputed from
    /// `baseArbitrationTuning`, through the NEW sensitivity trim, through whatever low-light state
    /// is currently in effect — never the other way around (see `applied(to:)`'s doc comment on
    /// `SensitivityTrim` for why sensitivity must compose FIRST, low light SECOND). Same
    /// actor-isolation/atomicity/state-preservation guarantees as `setLowLight` above.
    func setSensitivity(_ trim: SensitivityTrim) {
        currentSensitivity = trim
        recomputeTuning()
    }

    /// Clutch-optional setting (2026-08-24): called by `TacitEngine` whenever
    /// `"tacit.requiresClutch"` changes. Composed into the same recompute every other tuning
    /// source funnels through — see `recomputeTuning()`'s doc comment for the full order.
    /// `ArbitrationEngine.setTuning` itself is what resets `state`/the debounce/cooldown ledger on
    /// an actual `requiresClutch` flip (see that method's doc comment); this call is a plain
    /// pass-through, same shape as `setSensitivity`/`setLowLight`.
    func setClutchRequired(_ required: Bool) {
        currentRequiresClutch = required
        recomputeTuning()
    }

    /// Fix (M3 Task 7): the M3 Task 6 version of this recompute swapped `arbitration`'s tuning
    /// straight from `baseArbitrationTuning` through `LowLightPolicy.adjusted` alone — correct
    /// while sensitivity didn't exist yet, but it would silently DISCARD the sensitivity trim on
    /// every low-light flip (a low-light flip while "Eager" is selected would reset the user back
    /// to the un-sensitized baseline plus the low-light raise, not "Eager" plus the low-light
    /// raise). This is the single recompute `setLowLight`/`setSensitivity`/`setClutchRequired` all
    /// funnel through, always composed in the documented order: base →
    /// `currentSensitivity.applied(to:)` → `requiresClutch` folded in → `LowLightPolicy.adjusted(_,
    /// lowLight: isLowLight)` → (applied by `ArbitrationEngine` itself, at ingest time, from
    /// `tuning.clutchOffConfidenceBoost`) the clutch-off confidence boost. `requiresClutch` is
    /// folded in BEFORE the low-light adjustment — not after — purely so `LowLightPolicy.adjusted`
    /// (which copies the whole struct forward untouched aside from the two confidence fields it
    /// raises) is always the last, outermost step, matching every other tuning source here.
    private func recomputeTuning() {
        var sensitized = currentSensitivity.applied(to: baseArbitrationTuning)
        sensitized.requiresClutch = currentRequiresClutch
        arbitration.setTuning(LowLightPolicy.adjusted(sensitized, lowLight: isLowLight))
    }

    /// Enables/disables Task 19's preview computation above. Turning it ON always rebuilds all
    /// seven preview detectors (Task 19's original pair plus M3 Task 5's four dynamic detectors
    /// and `previewPinchDragDetector`) from scratch, so a freshly-opened card never inherits
    /// mid-gesture tracking state (e.g. a half-completed swipe or an in-progress rotation) left
    /// over from whichever card's preview ran before it. The momentary-candidate latch is cleared
    /// on EITHER transition (on or off) so a lit candidate from one card's session never bleeds
    /// into the next.
    func setPreviewActive(_ active: Bool) {
        previewActive = active
        previewLatch = nil
        if active {
            previewTapDetector = PinchTapDetector()
            previewSwipeDetector = ThumbSwipeDetector()
            previewHandSwipeDetector = HandSwipeDetector()
            previewFistToOpenDetector = FistToOpenDetector()
            previewWristRotateDetector = WristRotateDetector()
            previewTwoFingerScrollDetector = TwoFingerScrollDetector()
            previewPinchDragDetector = PinchDragDetector()
        }
    }
}
