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
    @Published private(set) var warning: String?
    @Published private(set) var lastEvent: GestureEvent?
    @Published private(set) var latestFrame: LandmarkFrame?

    let recorder: FixtureRecorder

    private static let enabledDefaultsKey = "tacit.enabled"

    private let capture = CaptureEngine()
    private var pipeline: PipelineCore?

    private var frameContinuation: AsyncStream<(CVPixelBuffer, TimeInterval)>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var fireResetTask: Task<Void, Never>?
    private var pauseResumeTask: Task<Void, Never>?
    private var hasStarted = false

    /// Latest arbitration phase seen from the pipeline, kept outside `PipelineCore` so
    /// `recomputeGlyphState()` can be driven by capture-state changes too (which arrive via
    /// Combine, not via a frame).
    private var lastArbitrationState: ArbitrationState = .disarmed

    private var cancellables: Set<AnyCancellable> = []

    init(recorder: FixtureRecorder = FixtureRecorder()) {
        self.recorder = recorder
        let stored = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool
        self.isEnabled = stored ?? true

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
    }

    // MARK: - Lifecycle

    /// Wires `capture.onFrame` (must happen before `capture.start()`, on the main actor — see
    /// `CaptureEngine`'s assertion) and starts the single pipeline-consuming `Task`. Safe to call
    /// more than once; only the first call has any effect.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let (stream, continuation) = AsyncStream<(CVPixelBuffer, TimeInterval)>.makeStream()
        frameContinuation = continuation

        let pipeline = PipelineCore()
        self.pipeline = pipeline

        capture.onFrame = { pixelBuffer, timestamp in
            continuation.yield((pixelBuffer, timestamp))
        }

        pipelineTask = Task { @MainActor [weak self] in
            for await (pixelBuffer, timestamp) in stream {
                let result = await pipeline.process(pixelBuffer: pixelBuffer, timestamp: timestamp)
                guard let self else { return }
                self.apply(result)
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
    func pause(for duration: TimeInterval) {
        pauseResumeTask?.cancel()
        capture.pause(reason: "Paused")
        pauseResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.pauseResumeTask = nil
            self.capture.resume()
        }
    }

    // MARK: - isEnabled / capture-state plumbing

    private func handleEnabledChange(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        if enabled {
            capture.resume()
        } else {
            capture.pause(reason: "Paused")
        }
        recomputeGlyphState()
    }

    private func handleCaptureStateChange(_ state: CaptureState) {
        updateWarning(for: state)
        if !isRunning(state) {
            // Capture stopped (paused, interrupted, or unavailable): drop any stale arbitration
            // progress so a later resume starts clean from `.disarmed` rather than momentarily
            // flashing whatever phase (e.g. `.armed`) was in effect right before the pause.
            lastArbitrationState = .disarmed
            if let pipeline {
                Task { await pipeline.reset() }
            }
        }
        recomputeGlyphState()
    }

    private func updateWarning(for state: CaptureState) {
        switch state {
        case .unavailable(let reason):
            warning = reason == "Camera access denied"
                ? "Camera access needed — open System Settings"
                : reason
        case .running, .paused:
            warning = nil
        }
    }

    private func isRunning(_ state: CaptureState) -> Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Per-frame pipeline results

    private func apply(_ result: PipelineCore.Result) {
        if let frame = result.frame {
            latestFrame = frame
            recorder.append(frame)
        } else {
            latestFrame = nil
        }

        lastArbitrationState = result.arbitrationState

        if let event = result.event {
            lastEvent = event
            pulseFired()
        } else {
            recomputeGlyphState()
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

    struct Result: Sendable {
        var frame: LandmarkFrame?
        var arbitrationState: ArbitrationState
        var event: GestureEvent?
    }

    /// Runs one captured frame through detection → classification → arbitration. Callers are
    /// expected (by `TacitEngine.start()`'s single consuming `Task`) to await each call to
    /// completion before issuing the next, so this never actually executes concurrently with
    /// itself — but even if it did, actor isolation would serialize it safely.
    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async -> Result {
        let frames = await detector.detect(in: pixelBuffer, timestamp: timestamp)
        let frame = frames.first
        let candidate = frame.flatMap(classifier.classify)
        let event = arbitration.ingest(candidate, at: timestamp)
        return Result(frame: frame, arbitrationState: arbitration.state, event: event)
    }

    /// Returns arbitration to `.disarmed` — called when capture stops, so a later resume doesn't
    /// briefly show stale progress from before the pause.
    func reset() {
        arbitration.reset()
    }
}
