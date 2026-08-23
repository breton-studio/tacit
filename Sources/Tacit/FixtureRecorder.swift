import Foundation
import TacitCore

/// Records a labeled clip of `LandmarkFrame`s to `~/Documents/TacitFixtures/` as a
/// `FixtureCodec`-encoded JSON file.
///
/// Passive sink, deliberately: this task builds the recorder before the live capture→detection
/// pipeline exists (that's Task 11's `TacitEngine`). `append(_:)` is the only way frames get in —
/// Task 11 calls it per-frame from wherever the pipeline runs. Nothing here reaches out to
/// capture or Vision itself.
///
/// Concurrency: `append(_:)` is `nonisolated` because Task 11's pipeline is expected to call it
/// from a background queue at capture-frame-rate. Rather than hop to `@MainActor` per frame, the
/// mutable buffer/flag it touches (`buffer`, `isRecordingUnsafe`) are marked
/// `nonisolated(unsafe)` and guarded by `lock` — a plain `NSLock` is cheaper here than an actor
/// hop on every frame. Everything else (`isRecording`, `remainingSeconds`, `lastError`, the
/// countdown timer, and the on-disk write) stays on the main actor, since it's UI-facing state
/// and file I/O triggered by a UI action.
@MainActor
final class FixtureRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var lastError: String?

    private let lock = NSLock()
    private nonisolated(unsafe) var buffer: [LandmarkFrame] = []
    private nonisolated(unsafe) var isRecordingUnsafe = false

    private var countdownTimer: Timer?
    private var pendingLabel = ""
    private let fixturesDirectory: URL

    init(fixturesDirectory: URL = FixtureRecorder.defaultFixturesDirectory) {
        self.fixturesDirectory = fixturesDirectory
    }

    static var defaultFixturesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TacitFixtures", isDirectory: true)
    }

    /// Begins a `seconds`-long countdown recording under `label`. Buffered frames (via
    /// `append(_:)`) accumulate until the countdown reaches zero, at which point the clip is
    /// written to disk and state resets. No-op while already recording.
    func start(seconds: TimeInterval, label: String) {
        guard !isRecording else { return }

        pendingLabel = label
        lock.withLock {
            buffer.removeAll()
            isRecordingUnsafe = true
        }

        lastError = nil
        remainingSeconds = max(0, Int(seconds.rounded()))
        isRecording = true

        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// Buffers `frame` while a recording is in progress; ignored otherwise. Safe to call from
    /// any thread/queue — see the concurrency note on the type.
    nonisolated func append(_ frame: LandmarkFrame) {
        lock.withLock {
            guard isRecordingUnsafe else { return }
            buffer.append(frame)
        }
    }

    private func tick() {
        guard isRecording else { return }
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            finish()
        }
    }

    private func finish() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        let frames: [LandmarkFrame] = lock.withLock {
            isRecordingUnsafe = false
            let captured = buffer
            buffer.removeAll()
            return captured
        }

        isRecording = false
        remainingSeconds = 0

        do {
            try FileManager.default.createDirectory(
                at: fixturesDirectory, withIntermediateDirectories: true)
            let filename = FixtureNaming.filename(label: pendingLabel, date: Date())
            let url = fixturesDirectory.appendingPathComponent(filename)
            let data = try FixtureCodec.encode(frames)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "Couldn't save fixture."
        }
    }
}
