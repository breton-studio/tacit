@preconcurrency import AVFoundation
import Foundation
import TacitCore

/// Current status of the camera capture pipeline.
enum CaptureState: Equatable {
    case running
    case paused(reason: String)
    case unavailable(reason: String)
}

/// Owns the `AVCaptureSession` that feeds camera frames into inference.
///
/// Frames arrive on the delegate callback on `captureQueue` (a dedicated serial queue, per
/// Apple's guidance for `AVCaptureVideoDataOutput`), get throttled to ~15 Hz by an
/// `InferenceThrottle` held by `SampleBufferDelegateBox` below, and only the frames that pass the
/// throttle are forwarded to `onFrame` — still on `captureQueue`, never on the main actor.
/// `state`, being `@Published`, is only ever written from the main actor: `start`/`pause`/`resume`
/// are all called on the main actor, and the `@objc` notification handlers below rely on
/// AVFoundation's documented contract that `AVCaptureSession.runtimeErrorNotification`,
/// `.wasInterruptedNotification`, and `.interruptionEndedNotification` are always posted on the
/// main thread. That is the *only* reason it's safe for these handlers to touch `state` directly:
/// selector-based `NotificationCenter` dispatch bypasses Swift's static actor-isolation checking
/// entirely — there is no compiler-inserted hop onto the main actor for `@objc` selector
/// callbacks, unlike a normal Swift call into an isolated method. Do **not** generalize this
/// pattern to a notification (or any other callback) that isn't documented to fire on the main
/// thread; without that guarantee, the handler must hop explicitly (e.g.
/// `Task { @MainActor in ... }`) before touching actor-isolated state, exactly as the frame
/// delegate below does via `onFrame`.
@MainActor
final class CaptureEngine: NSObject, ObservableObject {
    /// Current pipeline status, observable by SwiftUI.
    @Published private(set) var state: CaptureState = .paused(reason: "Not started")

    /// Invoked on `captureQueue` for every frame that survives the ~15 Hz throttle.
    ///
    /// Both the getter and setter are `nonisolated`: although this lives on a `@MainActor` class,
    /// it must be *read* from the capture queue (never the main actor) so the delegate box can
    /// call it synchronously without a `Task` hop per frame. The backing storage and the
    /// `hasStarted` guard below are `nonisolated(unsafe)` for the same reason. Callers are
    /// expected to set this once, from the main actor, before `start()` is called; `start()`
    /// flips `hasStarted` to enforce that write-once discipline — a set after that point trips an
    /// `assertionFailure` (crashing in debug) and is otherwise silently ignored, rather than
    /// racing the capture queue's reads.
    nonisolated var onFrame: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)? {
        get { onFrameStorage }
        set {
            guard !hasStarted else {
                assertionFailure("CaptureEngine.onFrame must be set before start() is called; ignoring late write")
                return
            }
            onFrameStorage = newValue
        }
    }

    private nonisolated(unsafe) var onFrameStorage: (@Sendable (CVPixelBuffer, TimeInterval) -> Void)?
    private nonisolated(unsafe) var hasStarted = false

    private let captureQueue = DispatchQueue(label: "studio.breton.tacit.capture")
    private let session = AVCaptureSession()

    /// Bridges `AVCaptureVideoDataOutput`'s delegate callback (fired on `captureQueue`, never the
    /// main actor) to this engine. Boxed separately, rather than conforming `CaptureEngine`
    /// itself to `AVCaptureVideoDataOutputSampleBufferDelegate`, so the delegate object is free of
    /// `@MainActor` isolation: it only touches its own private, queue-confined `throttle` and
    /// reads `engine.onFrame` (itself `nonisolated`) before forwarding the frame.
    private var delegateBox: SampleBufferDelegateBox?

    private var wasInterrupted = false

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Requests camera permission (if needed) and configures + starts the capture session.
    /// Safe to call once; call `resume()` to restart after a `pause`.
    func start() async {
        hasStarted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                configureAndStart()
            } else {
                state = .unavailable(reason: "Camera access denied")
            }
        case .denied, .restricted:
            state = .unavailable(reason: "Camera access denied")
        @unknown default:
            state = .unavailable(reason: "Camera access denied")
        }
    }

    /// Stops frame delivery and reports why, without tearing down the session.
    func pause(reason: String) {
        state = .paused(reason: reason)
        if session.isRunning {
            captureQueue.async { [session] in
                session.stopRunning()
            }
        }
    }

    /// Resumes a paused session.
    func resume() {
        guard case .paused = state else { return }
        captureQueue.async { [session] in
            session.startRunning()
        }
        state = .running
    }

    // MARK: - Configuration

    private func configureAndStart() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            state = .unavailable(reason: "No camera available")
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            session.commitConfiguration()
            state = .unavailable(reason: "Could not open camera")
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true

        let delegateBox = SampleBufferDelegateBox(engine: self)
        self.delegateBox = delegateBox
        output.setSampleBufferDelegate(delegateBox, queue: captureQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            // Best-effort: if we can't lock the device for configuration, proceed without
            // pinning the frame duration rather than failing capture entirely.
        }

        registerForNotifications()

        captureQueue.async { [session] in
            session.startRunning()
        }
        state = .running
    }

    // MARK: - Notifications

    private func registerForNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
    }

    @objc private func handleRuntimeError(_ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "Capture session runtime error"
        pause(reason: message)
    }

    @objc private func handleWasInterrupted(_ notification: Notification) {
        // `AVCaptureSessionInterruptionReasonKey` / `InterruptionReason` are iOS-only (marked
        // API_UNAVAILABLE(macos) in the SDK), so on macOS we only get told *that* the session was
        // interrupted, not why.
        wasInterrupted = true
        state = .paused(reason: "Capture interrupted")
    }

    @objc private func handleInterruptionEnded(_ notification: Notification) {
        guard wasInterrupted else { return }
        wasInterrupted = false
        resume()
    }

    // MARK: - Teardown

    /// Belt-and-braces: `NotificationCenter` observers registered via `addObserver(_:selector:...)`
    /// are not automatically removed on deinit pre-iOS 9/macOS 10.11, and explicit removal makes
    /// the observer's lifetime clear at the call site regardless. `removeObserver(_:)` is
    /// documented as safe to call from any thread, so this needs no actor hop.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Non-isolated `NSObject` box that receives `AVCaptureVideoDataOutputSampleBufferDelegate`
/// callbacks on `captureQueue` and applies the ~15 Hz `InferenceThrottle` before forwarding to
/// `CaptureEngine`. It is declared `@unchecked Sendable` because AVFoundation calls it from an
/// arbitrary (non-Swift-concurrency-tracked) queue; the only mutable state it owns —
/// `throttle` — is only ever touched from that one serial queue, so the lack of compiler-enforced
/// isolation is safe in practice.
private final class SampleBufferDelegateBox: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private weak var engine: CaptureEngine?
    private var throttle = InferenceThrottle(minInterval: 1.0 / 15.0)

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard throttle.shouldRun(at: timestamp) else { return }
        engine?.onFrame?(pixelBuffer, timestamp)
    }
}
