@preconcurrency import AVFoundation
import CoreVideo
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

    /// Invoked on `captureQueue` roughly every 2 s with the frame's mean luma (0…1, cheap coarse
    /// sample — see `SampleBufferDelegateBox.meanLuma(of:)`) and its presentation timestamp.
    ///
    /// Same write-once discipline as `onFrame` above, for the same reason: both the getter and
    /// setter are `nonisolated` so `SampleBufferDelegateBox` can read/call it synchronously from
    /// the capture queue without a `Task` hop, backing storage is `nonisolated(unsafe)`, and
    /// `start()` flips `hasStarted` to enforce "set once, from the main actor, before `start()`" —
    /// a set after that point trips an `assertionFailure` (crashing in debug) and is otherwise
    /// silently ignored, rather than racing the capture queue's reads.
    nonisolated var onLuma: (@Sendable (Double, TimeInterval) -> Void)? {
        get { onLumaStorage }
        set {
            guard !hasStarted else {
                assertionFailure("CaptureEngine.onLuma must be set before start() is called; ignoring late write")
                return
            }
            onLumaStorage = newValue
        }
    }

    private nonisolated(unsafe) var onLumaStorage: (@Sendable (Double, TimeInterval) -> Void)?
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
    ///
    /// No-ops while `state` is `.unavailable`: that state means there's no running session to stop
    /// in the first place (camera denied, no device, couldn't open it — `configureAndStart()` bails
    /// out before ever starting `session`), and overwriting `.unavailable` with `.paused(reason:)`
    /// would erase the underlying camera warning (`TacitEngine.updateWarning` derives `warning` from
    /// this state) for as long as the pause lasts — e.g. "Pause for an Hour" or the master toggle
    /// while camera access is denied would silently swap "Camera access needed" for "Paused" and
    /// never bring it back. `resume()` below guards symmetrically, only ever transitioning out of
    /// `.paused`.
    func pause(reason: String) {
        if case .unavailable = state { return }
        state = .paused(reason: reason)
        if session.isRunning {
            captureQueue.async { [session] in
                session.stopRunning()
            }
        }
    }

    /// Resumes a paused session. No-ops unless `state` is currently `.paused` — in particular,
    /// never resumes from `.unavailable` (there's no configured session to start) or from
    /// `.running` (already running).
    func resume() {
        guard case .paused = state else { return }
        captureQueue.async { [session] in
            session.startRunning()
        }
        state = .running
    }

    // MARK: - Camera selection (M3 Task 7: Settings tab camera picker)

    /// Switches the active camera input to the device with `uniqueID`, falling back to the
    /// default built-in wide-angle camera when `uniqueID` is `nil` or no longer resolves to an
    /// available device (e.g. a persisted external/Continuity camera was unplugged since the
    /// selection was made). Persistence of the selection itself (`"tacit.cameraID"`) is the
    /// caller's job — `TacitEngine.cameraID`'s `didSet` — this method only performs the live
    /// session reconfiguration.
    ///
    /// No-op while `state` is `.unavailable`: exactly like `pause(reason:)`/`resume()` above,
    /// `.unavailable` means `configureAndStart()` never got a session running in the first place
    /// (permission denied, no camera present, couldn't open the device) — there is no input to
    /// swap, and attempting to reconfigure anyway would risk resurrecting a session nobody asked
    /// to run behind a state that's supposed to keep reporting the same unavailability reason.
    /// `state` itself is left completely untouched by this method either way: switching cameras
    /// never changes whether the pipeline is running, paused, or unavailable, only which physical
    /// device feeds it while running/paused.
    ///
    /// The actual `AVCaptureSession` mutation runs on `captureQueue` (not the main actor) per
    /// Apple's guidance for reconfiguring a session that may currently be running — mirrored from
    /// `pause(reason:)`/`resume()`'s existing `captureQueue.async { [session] in ... }` convention
    /// in this file, just extended to cover `beginConfiguration()`/`commitConfiguration()` and the
    /// device lock too (unlike `configureAndStart()`, which — being the one-time initial setup,
    /// with nothing yet running to protect — does that work synchronously on the main actor
    /// instead).
    func switchCamera(to uniqueID: String?) {
        if case .unavailable = state { return }
        captureQueue.async { [session] in
            Self.performCameraSwitch(session: session, to: uniqueID)
        }
    }

    /// Off-main-actor camera-input swap: resolves the requested device (or its default-camera
    /// fallback), builds its `AVCaptureDeviceInput` FIRST — before touching `session` at all — so
    /// that a device that fails to open (e.g. already claimed by another process) leaves whatever
    /// input is currently running completely untouched rather than tearing it down for a
    /// replacement that doesn't work.
    ///
    /// **Rollback on a rejected input (post-review fix):** `session.canAddInput(_:)` can only be
    /// trusted to answer "would the NEW input work" once the OLD input is no longer attached — a
    /// session generally allows only one video input at a time, so checking `canAddInput(newInput)`
    /// *before* removing the old one would almost always report `false` regardless of whether the
    /// new device is actually fine. That means the check has to happen strictly between "remove
    /// the old input" and "add the new one" — the exact window where a naive implementation would
    /// silently leave the session with **zero** video inputs if the new device turns out to be
    /// rejected for some OTHER reason (e.g. a format/preset mismatch the current
    /// `sessionPreset` can't satisfy), contradicting the "leave things untouched on failure"
    /// guarantee this method documents above. The fix: keep a reference to the previous input(s)
    /// (`session.inputs`, read before removing anything) so that if `canAddInput(newInput)` comes
    /// back `false` after the removal, this re-adds every previous input and commits — the session
    /// ends up in EXACTLY the state it started in, not a zero-input one — instead of proceeding.
    /// `activeVideoMinFrameDuration` is only re-pinned on the success path, since the rollback path
    /// never touches `device` (the request was rejected; nothing about it should be configured).
    private nonisolated static func performCameraSwitch(session: AVCaptureSession, to uniqueID: String?) {
        guard let device = resolvedDevice(for: uniqueID) else { return }

        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            return
        }

        session.beginConfiguration()

        let previousInputs = session.inputs
        for input in previousInputs {
            session.removeInput(input)
        }

        guard session.canAddInput(newInput) else {
            // Rollback: put every previous input back exactly as it was, rather than leaving the
            // session with zero video inputs while `state` still claims `.running`/`.paused` as if
            // nothing happened.
            for input in previousInputs where session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            return
        }

        session.addInput(newInput)
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        } catch {
            // Best-effort, matching `configureAndStart()`: proceed without pinning the frame
            // duration rather than failing the whole switch over a lock failure.
        }
    }

    /// `uniqueID`'s device if it still resolves to one, else the default built-in wide-angle
    /// camera (the same device `configureAndStart()` opens on first launch) — the "graceful
    /// fallback" required by the M3 Task 7 brief. Returns `nil` only if NEITHER resolves (e.g. no
    /// camera hardware at all), in which case `performCameraSwitch` leaves the existing input
    /// alone rather than tearing it down for nothing.
    private nonisolated static func resolvedDevice(for uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
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

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            state = .unavailable(reason: "Could not open camera")
            return
        }
        // Post-review sweep (same class of bug fixed in `performCameraSwitch` above): the old
        // `if session.canAddInput(input) { session.addInput(input) }` silently proceeded to add
        // the output, commit, and set `state = .running` even if the input was REJECTED — a
        // truthful-state violation (no video input attached, yet `state` claims `.running`).
        // There's no rollback to perform here (this is the session's first-ever configuration;
        // nothing was attached before), so the fix is simply to treat a rejected input as the
        // same failure `AVCaptureDeviceInput(device:)` throwing would be.
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            state = .unavailable(reason: "Could not open camera")
            return
        }
        session.addInput(input)

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
/// `throttle` and `lumaThrottle` — is only ever touched from that one serial queue, so the lack of
/// compiler-enforced isolation is safe in practice.
private final class SampleBufferDelegateBox: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private weak var engine: CaptureEngine?
    private var throttle = InferenceThrottle(minInterval: 1.0 / 15.0)
    /// M3 Task 6: gates `onLuma` to roughly once every 2 s — independent of, and checked before,
    /// `throttle` above — so the luma sample keeps landing on schedule even on a raw frame that
    /// `throttle` will go on to drop for the ~15 Hz frame path. The sampling work itself
    /// (`meanLuma(of:)` below) only actually runs on the rare frame that clears this throttle;
    /// every other frame pays just one cheap timestamp comparison, so the frame path is not
    /// slowed by this.
    private var lumaThrottle = InferenceThrottle(minInterval: 2.0)

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

        if lumaThrottle.shouldRun(at: timestamp) {
            engine?.onLuma?(Self.meanLuma(of: pixelBuffer), timestamp)
        }

        guard throttle.shouldRun(at: timestamp) else { return }
        engine?.onFrame?(pixelBuffer, timestamp)
    }

    // MARK: - Luma sampling (M3 Task 6)

    /// Coarse mean luma (0…1) of `pixelBuffer`, sampled on a stride rather than every pixel —
    /// cheap enough to run on the capture queue without perturbing the frame path, especially
    /// since `lumaThrottle` above only lets this run once every ~2 s. Handles the two pixel
    /// formats `AVCaptureVideoDataOutput` can hand back on macOS: biplanar 4:2:0 YCbCr (the luma
    /// plane IS the Y channel — sampled directly) and 32-bit BGRA (no dedicated luma channel, so
    /// `(r+g+b)/3` stands in for it). Any other format returns a neutral 0.5 rather than guessing
    /// at a layout it doesn't recognize.
    fileprivate static func meanLuma(of pixelBuffer: CVPixelBuffer) -> Double {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return meanBiplanarLuma(of: pixelBuffer)
        case kCVPixelFormatType_32BGRA:
            return meanBGRALuma(of: pixelBuffer)
        default:
            return 0.5
        }
    }

    /// Stride (in samples, both axes) used by both sampling paths below — "every 32nd pixel" per
    /// the task brief; plenty for a coarse ambient-brightness read, nowhere near a full-resolution
    /// scan.
    private static let sampleStride = 32

    private static func meanBiplanarLuma(of pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Plane 0 of a biplanar 4:2:0 buffer IS the luma (Y) plane, one byte per sample.
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0.5 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0
            while x < width {
                sum += Int(bytes[rowStart + x])
                count += 1
                x += sampleStride
            }
            y += sampleStride
        }
        guard count > 0 else { return 0.5 }
        return Double(sum) / Double(count) / 255.0
    }

    private static func meanBGRALuma(of pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.5 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0
            while x < width {
                let offset = rowStart + x * 4
                let b = Int(bytes[offset])
                let g = Int(bytes[offset + 1])
                let r = Int(bytes[offset + 2])
                sum += (r + g + b) / 3
                count += 1
                x += sampleStride
            }
            y += sampleStride
        }
        guard count > 0 else { return 0.5 }
        return Double(sum) / Double(count) / 255.0
    }
}
