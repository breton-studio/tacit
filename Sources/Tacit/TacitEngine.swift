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
    /// Routes a fired, bound `TacitAction` to its real macOS side effect. Constructed once with
    /// the live environment — see `handleFire(_:)` for why `dispatch(_:)` itself must never be
    /// called from the main actor.
    private let actionDispatcher = ActionDispatcher(environment: LiveActionEnvironment.make())
    /// The one HUD panel instance for real gesture fires, shown/errored by `handleFire(_:)`.
    /// (`PopoverView`'s ⌥-debug section keeps its own separate, never-wired `HUDController` for
    /// eyeballing motion manually — see that file's doc comment — so the two never collide.)
    let hudController = HUDController()

    private static let enabledDefaultsKey = "tacit.enabled"
    private static let hudEnabledDefaultsKey = "tacit.hudEnabled"
    /// Task 21 controller ruling (R4): set the first time — ever — a mapped gesture successfully
    /// performs its action, so that one fire (and only that one) can ask the HUD for a slightly
    /// grander constellation draw-on. Lives here, not in `TacitCore` (no `UserDefaults` there).
    private static let firstFireCelebratedKey = "tacit.firstFireCelebrated"

    private let capture = CaptureEngine()
    private var pipeline: PipelineCore?

    private var frameContinuation: AsyncStream<(CVPixelBuffer, TimeInterval)>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var fireResetTask: Task<Void, Never>?
    private var pauseResumeTask: Task<Void, Never>?
    private var accessibilityCheckTask: Task<Void, Never>?
    private var hasStarted = false

    /// True only while the current `capture` pause was raised by `handleScreenPauseSignal` below
    /// (screen locked or display asleep) — never by the user's own master toggle or "Pause for an
    /// Hour". Gates `handleScreenResumeSignal`'s auto-resume (spec §3.1/§6: locking the screen must
    /// pause detection, and unlocking must resume it, but ONLY the pause it itself caused): a screen
    /// unlock/wake must never override a pause the user asked for on purpose. Set `false` unconditionally
    /// by `handleEnabledChange` and `pause(for:)` — the two user-initiated pause paths — so a lock
    /// that happens to overlap with either of those can never sneak an unwanted auto-resume in later.
    ///
    /// Also written to `true` by `pause(for:)`'s own timer completion — see `isScreenLocked` below —
    /// when the hour elapses while the screen is still locked/asleep: that hands the eventual resume
    /// off to `handleScreenResumeSignal` instead of resuming immediately behind a locked screen.
    private var isScreenLockPaused = false
    /// True while the screen is CURRENTLY locked or the display asleep — set by
    /// `handleScreenPauseSignal`, cleared by `handleScreenResumeSignal`, entirely independent of
    /// `isScreenLockPaused` above (which tracks WHO caused the current pause, not whether the lock
    /// is still in effect right now). Post-review fix: without this, `pause(for:)`'s timer
    /// completion had no way to know the screen was still locked when the hour elapsed, and would
    /// call `capture.resume()` unconditionally — restarting capture behind a locked screen, exactly
    /// what I2 exists to prevent. `pause(for:)`'s completion checks this flag before resuming.
    private var isScreenLocked = false
    /// Tokens for the block-based observers registered by `registerForScreenStateNotifications()`,
    /// paired with the center each was registered on (`DistributedNotificationCenter` is a
    /// `NotificationCenter` subclass, so both fit this one array) — removed in `deinit`. Declared
    /// `nonisolated(unsafe)` (matching `CaptureEngine.onFrameStorage`'s rationale) purely so `deinit`
    /// — which, like every Swift `deinit`, runs nonisolated even on a `@MainActor` class — can read
    /// it to remove the observers; every other access is from `init`/`registerForScreenStateNotifications()`
    /// on the main actor, and by the time `deinit` runs nothing else can be touching this instance.
    private nonisolated(unsafe) var systemStateObserverTokens: [(NotificationCenter, NSObjectProtocol)] = []

    /// The two components `warning` is derived from (spec §6): a camera-side message (from
    /// `CaptureState`) and an Accessibility-side message (from the poll wired in `init` below).
    /// Kept separate rather than overwriting one `warning` in place so neither source can clobber
    /// the other's message — `recomputeWarning()` is the only place they're combined, camera
    /// taking priority since a camera problem blocks everything downstream of it.
    private var captureWarning: String?
    private var accessibilityWarning: String?
    /// True while at least one ENABLED binding's action `requiresAccessibility` — recomputed
    /// whenever `mappingStore.bindings` changes (wired below, in `init`). Kept as a stored flag
    /// (rather than re-scanning bindings on every 5 s poll tick) so the poll loop only ever has to
    /// ask one question: is Accessibility trusted right now.
    private var enabledKeystrokeBindingExists = false

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
        self.recorder = recorder
        let stored = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool
        self.isEnabled = stored ?? true
        let storedHUDEnabled = UserDefaults.standard.object(forKey: Self.hudEnabledDefaultsKey) as? Bool
        self.isHUDEnabled = storedHUDEnabled ?? true

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
            }
            .store(in: &cancellables)

        accessibilityCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.recomputeAccessibilityWarning()
                try? await Task.sleep(for: .seconds(5))
            }
        }

        registerForScreenStateNotifications()
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

        capture.onFrame = { pixelBuffer, timestamp in
            continuation.yield((pixelBuffer, timestamp))
        }

        pipelineTask = Task { @MainActor [weak self] in
            for await (pixelBuffer, timestamp) in stream {
                guard let self else { return }
                // Read the generation *before* the (potentially slow) process() call, so a
                // reset that happens while this frame is in flight is detected on return — see
                // `apply(_:generation:)`.
                let generation = self.pipelineGeneration
                let result = await pipeline.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
                self.apply(result, generation: generation)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.capture.start()
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
    /// Post-review fix: the completion no longer resumes unconditionally. If the screen is STILL
    /// locked/asleep (`isScreenLocked`) when the timer fires, resuming here would restart capture
    /// behind a locked screen — exactly what I2 exists to prevent. Instead it hands off: marks
    /// `isScreenLockPaused = true` so the eventual unlock/wake signal (`handleScreenResumeSignal`)
    /// performs the resume itself once the screen actually comes back.
    func pause(for duration: TimeInterval) {
        pauseResumeTask?.cancel()
        // User-initiated: always wins over a pending screen-lock auto-resume (see
        // `isScreenLockPaused`'s doc comment).
        isScreenLockPaused = false
        capture.pause(reason: "Paused")
        pauseResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.pauseResumeTask = nil
            if self.isScreenLocked {
                self.isScreenLockPaused = true
                return
            }
            self.capture.resume()
        }
    }

    // MARK: - isEnabled / capture-state plumbing

    private func handleEnabledChange(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        // User-initiated: always wins over a pending screen-lock auto-resume (see
        // `isScreenLockPaused`'s doc comment).
        isScreenLockPaused = false
        if enabled {
            // Deliberately resumes unconditionally, even if `isScreenLocked` is still true: this is
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
    /// sleep via Energy Saver, closing a laptop lid with an external display, etc). Both call into
    /// the same pause/resume pair below because either one alone means "nobody is looking at the
    /// screen right now" (spec §3.1/§6).
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
                self?.handleScreenPauseSignal(reason: "Screen locked")
            }
        }
        let unlockToken = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenResumeSignal()
            }
        }
        let sleepToken = workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenPauseSignal(reason: "Display asleep")
            }
        }
        let wakeToken = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenResumeSignal()
            }
        }

        systemStateObserverTokens = [
            (distributed, lockToken),
            (distributed, unlockToken),
            (workspace, sleepToken),
            (workspace, wakeToken),
        ]
    }

    /// Marks `isScreenLocked = true` unconditionally — that bookkeeping has to stay accurate
    /// regardless of what capture is doing, since `pause(for:)`'s timer completion depends on it
    /// even while capture is already paused for some other reason. Only PAUSES (and only marks the
    /// pause as system-initiated via `isScreenLockPaused`) while capture is actually `.running` — if
    /// it's already `.paused` (user disabled it, or mid "Pause for an Hour") or `.unavailable` (no
    /// camera), there's nothing for this signal to do to `capture`, and critically `isScreenLockPaused`
    /// must stay `false` so the matching unlock/wake never resumes a pause it didn't cause.
    private func handleScreenPauseSignal(reason: String) {
        isScreenLocked = true
        guard case .running = capture.state else { return }
        isScreenLockPaused = true
        capture.pause(reason: reason)
    }

    /// Clears `isScreenLocked` unconditionally (mirrors `handleScreenPauseSignal` always setting
    /// it), then resumes only if `isScreenLockPaused` is still set — i.e. nothing user-initiated
    /// (master toggle, "Pause for an Hour") has happened since the matching lock/sleep signal paused
    /// capture, AND `pause(for:)`'s timer completion didn't already resume before this fired. Also
    /// what performs the deferred resume when `pause(for:)`'s timer elapsed while still locked (see
    /// that method's doc comment). `capture.resume()` itself only transitions out of `.paused`, so
    /// this is additionally safe even if `state` somehow became `.unavailable` in between.
    private func handleScreenResumeSignal() {
        isScreenLocked = false
        guard isScreenLockPaused else { return }
        isScreenLockPaused = false
        capture.resume()
    }

    private func handleCaptureStateChange(_ state: CaptureState) {
        updateWarning(for: state)
        if !isRunning(state) {
            // Capture stopped (paused, interrupted, or unavailable): drop any stale arbitration
            // progress so a later resume starts clean from `.disarmed` rather than momentarily
            // flashing whatever phase (e.g. `.armed`) was in effect right before the pause.
            // Bumping the generation here — before the reset actually completes on the pipeline
            // actor — is what lets `apply(_:generation:)` deterministically discard any frame
            // already in flight, no matter when it resolves.
            pipelineGeneration += 1
            lastArbitrationState = .disarmed
            // No live frame is coming while capture is stopped: a stale preview candidate must not
            // keep a card lit (requirement 5 — a paused strip shows the dimmed canned frame only).
            previewCandidate = nil
            if let pipeline {
                Task { await pipeline.reset() }
            }
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

    /// `warning`'s single point of combination (spec §6): a camera problem takes priority — it
    /// blocks recognition entirely, whereas the Accessibility gap only disables keystroke actions
    /// specifically — so it's shown first if both are true at once.
    private func recomputeWarning() {
        warning = captureWarning ?? accessibilityWarning
    }

    // MARK: - Accessibility warning (spec §6, Task 20; wired in `init`, Task 21)

    private func recomputeAccessibilityWarning() {
        accessibilityWarning = (enabledKeystrokeBindingExists && !AXIsProcessTrusted())
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
    private func apply(_ result: PipelineCore.Result, generation: Int) {
        guard generation == pipelineGeneration else { return }

        if let frame = result.frame {
            latestFrame = frame
            recorder.append(frame)
        } else {
            latestFrame = nil
        }

        lastArbitrationState = result.arbitrationState

        // Re-check the MainActor's own `isPreviewActive` (not just whatever this frame's
        // `PipelineCore` happened to compute) so a preview turned off *after* this frame was
        // already in flight can't resurrect a stale lit candidate — the same race the `didSet`
        // above already guards against on the "turn off" side.
        previewCandidate = isPreviewActive ? result.previewCandidate : nil

        if let event = result.event {
            lastEvent = event
            pulseFired()
            handleFire(event)
        } else {
            recomputeGlyphState()
        }
    }

    // MARK: - Closing the loop: gesture event → dispatched action → HUD (Task 21)

    /// Looks up `event.gesture`'s binding and, if it's enabled and bound to an action, dispatches
    /// it and shows the resulting HUD feedback. Reserved gestures (`.looseFist`/`.openPalm`),
    /// unbound gestures (`action == nil`), and disabled bindings all no-op here — no dispatch, no
    /// HUD — matching the brief exactly; the glyph's fire pulse above already happened
    /// unconditionally regardless of binding state.
    private func handleFire(_ event: GestureEvent) {
        let binding = mappingStore.binding(for: event.gesture)
        guard binding.enabled, let action = binding.action else { return }

        // `ActionDispatcher.dispatch` must NEVER be called from the main actor: `.keystroke`
        // synchronously posts a `CGEvent` and `.runShortcut` blocks on `Process.waitUntilExit()`
        // (see `LiveActionEnvironment.runShortcut`'s doc comment) — either could stall the UI for
        // as long as the Shortcut takes to run. `actionDispatcher` (a `Sendable` struct of
        // `@Sendable` closures) and `action`/`gesture`/`frame` (all `Sendable` value types) are
        // captured into a `Task.detached` that runs off any actor; only the resulting UI update
        // hops back to the main actor via `MainActor.run`.
        let dispatcher = actionDispatcher
        let gesture = event.gesture
        let frame = latestFrame

        Task.detached { [weak self] in
            let outcome = dispatcher.dispatch(action)
            await MainActor.run {
                self?.applyDispatchOutcome(outcome, gesture: gesture, action: action, frame: frame)
            }
        }
    }

    /// The main-actor-side half of `handleFire(_:)`, run once `actionDispatcher.dispatch` returns.
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
            return .armed
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

    /// Task 21 controller ruling (R2): the PRODUCTION tap/swipe detectors, run on every frame
    /// regardless of arbitration state — their own internal tracking (an in-progress pinch or
    /// swipe) has to keep evolving through disarmed/arming frames so it's already primed the
    /// instant the clutch arms. SEPARATE instances from `previewTapDetector`/`previewSwipeDetector`
    /// below, so a card-detail preview session's tracking state can never leak into (or be leaked
    /// into by) production recognition.
    private var tapDetector = PinchTapDetector()
    private var swipeDetector = ThumbSwipeDetector()

    /// Task 19's perform-to-preview mode: `false` unless a `CardDetailView` preview strip is
    /// currently mounted (see `TacitEngine.isPreviewActive`). `previewTapDetector` /
    /// `previewSwipeDetector` are SEPARATE instances from the production ones above so preview
    /// state can never cross into or out of the arbitration path.
    private var previewActive = false
    private var previewTapDetector = PinchTapDetector()
    private var previewSwipeDetector = ThumbSwipeDetector()
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
    }

    /// Runs one captured frame through detection → classification → arbitration. Callers are
    /// expected (by `TacitEngine.start()`'s single consuming `Task`) to await each call to
    /// completion before issuing the next, so this never actually executes concurrently with
    /// itself — but even if it did, actor isolation would serialize it safely.
    ///
    /// Task 21 controller ruling (R2), production event precedence: `tapDetector`/`swipeDetector`
    /// run on EVERY frame (unconditionally, not gated on `previewActive` or on arbitration state).
    /// The static candidate is ingested into `arbitration.ingest` FIRST, exactly as before — the
    /// clutch/disarm path must see every frame regardless of what a momentary detector does. THEN
    /// a momentary candidate (`tap ?? swipe`, if either fired this frame) goes through the separate
    /// `arbitration.ingestPreDebounced` entry point (see that method's doc comment — momentary
    /// candidates are already self-debounced in time by their own detectors and could never
    /// satisfy `ingest`'s 3-frame debounce). If BOTH return an event on the same frame, the
    /// momentary one wins: it's what this function returns, and the static event is ledger-dropped
    /// — `ingest`'s own bookkeeping (cooldown, window extension) for that static fire already
    /// happened above and is never undone, only which `GestureEvent` is reported to `TacitEngine`
    /// differs.
    ///
    /// When `previewActive`, this ALSO runs the frame through preview-scoped
    /// `PinchTapDetector`/`ThumbSwipeDetector` instances, entirely independent of (and never
    /// feeding into) `arbitration` — nothing below this point ever reads back into `arbitration` or
    /// the production `candidate`/`event` values.
    ///
    /// `previewCandidate` precedence: a freshly-firing tap/swipe candidate this frame > an
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

        let momentary = frame.flatMap { tapDetector.ingest($0) ?? swipeDetector.ingest($0) }
        let preDebouncedEvent = momentary.flatMap { arbitration.ingestPreDebounced($0, at: timestamp) }
        let event = preDebouncedEvent ?? staticEvent

        var previewCandidate: GestureCandidate?
        if previewActive {
            if let frame {
                let momentary = previewTapDetector.ingest(frame) ?? previewSwipeDetector.ingest(frame)
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
            previewCandidate: previewCandidate
        )
    }

    /// Returns arbitration to `.disarmed` — called when capture stops, so a later resume doesn't
    /// briefly show stale progress from before the pause.
    func reset() {
        arbitration.reset()
    }

    /// Enables/disables Task 19's preview computation above. Turning it ON always rebuilds both
    /// preview detectors from scratch, so a freshly-opened card never inherits mid-gesture tracking
    /// state (e.g. a half-completed swipe) left over from whichever card's preview ran before it.
    /// The momentary-candidate latch is cleared on EITHER transition (on or off) so a lit tap/swipe
    /// from one card's session never bleeds into the next.
    func setPreviewActive(_ active: Bool) {
        previewActive = active
        previewLatch = nil
        if active {
            previewTapDetector = PinchTapDetector()
            previewSwipeDetector = ThumbSwipeDetector()
        }
    }
}
