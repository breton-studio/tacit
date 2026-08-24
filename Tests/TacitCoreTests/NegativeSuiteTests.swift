import Foundation
import Testing
@testable import TacitCore

/// Midas-touch negative suite (Task 13).
///
/// Proves that incidental hand activity — typing at a keyboard, gesturing while talking — never
/// fires a `GestureEvent` and never arms the clutch, when replayed through the exact same
/// recognition chain the positive fixtures (`FixtureReplayTests`) exercise: classifier + tap
/// detector + swipe detector feeding `ArbitrationEngine`.
///
/// `Tests/Fixtures/` is empty as of this writing; recorded `typing-negative*`/
/// `conversation-negative*` fixtures land later from a human recording session. Until then (and
/// forever after, as an always-on regression net independent of what's been recorded), this
/// suite's load-bearing coverage is two synthetic streams built below with a deterministic
/// pseudo-random walk — never `Date()`, never `SystemRandomNumberGenerator` — so results are
/// identical on every run:
///
/// - `syntheticTypingStream`: 60 s @ 15 Hz (900 frames) jittering `SyntheticHand.typingHand`.
/// - `syntheticConversationStream`: 30 s @ 15 Hz (450 frames) oscillating between typingHand-ish
///   and openPalm-ish openness while the whole hand translates/waves across the frame.
///
/// Neither stream is shaped to dodge fist geometry — the jitter is a genuine random walk with no
/// guard against passing through `.looseFist`-adjacent poses. If a false arm shows up, the fix
/// belongs in the generator (if the excursion is unrealistic) or in tuning (if it's a real
/// detector sensitivity problem) — never a special case here. See the report for what happened
/// when this suite was first run, and for a since-corrected mistake: an earlier revision shortened
/// the jitter's autocorrelation time (to stop it lingering near fist geometry for a clutch-hold's
/// worth of frames) but shrank the noise's steady-state amplitude by ~43% in the process, which
/// quietly made the suite *less* likely to ever probe the boundary it exists to police. Both
/// generators below now decorrelate faster **and** preserve the original steady-state spread —
/// see `amplitudePreservingStep` — and the disarmed assertions run across an 11-seed sweep rather
/// than one hand-picked seed, so a single lucky draw can no longer hide a regression.
struct NegativeSuiteTests {

    // MARK: - Deterministic PRNG

    /// splitmix64. Fully deterministic given a seed: no wall-clock, no system entropy. Used to
    /// build every synthetic stream below so the suite is bit-for-bit reproducible run to run.
    struct SeededGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// Uniform in `[0, 1)`.
        mutating func nextUnit() -> Double {
            Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
        }

        /// Uniform in `[-1, 1)`.
        mutating func nextSigned() -> Double {
            nextUnit() * 2 - 1
        }
    }

    // MARK: - Full-chain replay helper

    /// Runs `frames` through the full recognition chain and `engine`, one frame at a time,
    /// mirroring `PipelineCore.process` (`Sources/Tacit/TacitEngine.swift`) and the `Harness` in
    /// `PipelineIntegrationTests.swift` EXACTLY — not just in detector precedence order but in the
    /// two-entry-point architecture itself (M3 Task 5 correction: the pre-Task-5 version of this
    /// function merged a momentary candidate and the static candidate into ONE combined value
    /// and fed it through a single `engine.ingest` call — a simplification that predates Task 21's
    /// `ingestPreDebounced` split and was never actually equivalent to production: a momentary
    /// detector's single-frame candidate could never satisfy `ingest`'s 3-consecutive-frame
    /// debounce, so it could effectively never fire through that path regardless of how deliberate
    /// the motion was — silently under-testing the exact risk this suite exists to police. Fixed
    /// to match Harness/PipelineCore precisely):
    ///
    /// 1. The static classifier's candidate goes to `engine.ingest` first, unconditionally — the
    ///    clutch/disarm path, exactly as before.
    /// 2. A momentary candidate — **tap > thumbSwipe > handSwipe > fistToOpen > rotate tick >
    ///    scroll tick** (first non-nil wins; identical order to `PipelineCore.process` and
    ///    `Harness` — keep all three in lockstep) — goes through `engine.ingestPreDebounced`
    ///    separately. `PinchDragDetector` is deliberately absent: it's preview-only (plan ruling
    ///    2) and never appears in any production/negative-suite chain.
    /// 3. If both return an event on the same frame, the momentary one wins, matching
    ///    `PipelineCore.process`'s ledger-drop rule exactly.
    ///
    /// Returns every fired `GestureEvent`, in order, and `everArmed` — whether `engine.state` was
    /// ever observed as `.armed` at any point during replay (i.e. whether an arming hold ever
    /// crossed the clutch threshold; see `ArbitrationTuning.clutchHold`).
    static func replayThroughFullChain(
        frames: [LandmarkFrame], engine: ArbitrationEngine
    ) -> (events: [GestureEvent], everArmed: Bool) {
        let classifier = StaticPoseClassifier()
        var tapDetector = PinchTapDetector()
        var swipeDetector = ThumbSwipeDetector()
        var handSwipeDetector = HandSwipeDetector()
        var fistToOpenDetector = FistToOpenDetector()
        var wristRotateDetector = WristRotateDetector()
        var twoFingerScrollDetector = TwoFingerScrollDetector()

        var events: [GestureEvent] = []
        var everArmed = false

        for frame in frames {
            let poseCandidate = classifier.classify(frame)
            let staticEvent = engine.ingest(poseCandidate, at: frame.timestamp)

            let momentaryCandidate = tapDetector.ingest(frame)
                ?? swipeDetector.ingest(frame)
                ?? handSwipeDetector.ingest(frame)
                ?? fistToOpenDetector.ingest(frame)
                ?? wristRotateDetector.ingest(frame)
                ?? twoFingerScrollDetector.ingest(frame)
            let preDebouncedEvent = momentaryCandidate.flatMap { engine.ingestPreDebounced($0, at: frame.timestamp) }

            if let event = preDebouncedEvent ?? staticEvent {
                events.append(event)
            }

            switch engine.state {
            case .armed: everArmed = true
            default: break
            }
        }

        return (events, everArmed)
    }

    // MARK: - Amplitude-preserving AR(1) derivation

    /// For `offset_t = offset_{t-1} * decay + Uniform(-step, step)`, the stationary variance is
    /// `Var(noise) / (1 - decay^2) = (step^2 / 3) / (1 - decay^2)`, so the steady-state standard
    /// deviation is `step / sqrt(3 * (1 - decay^2))`.
    ///
    /// Given a `referenceStep`/`referenceDecay` pair whose resulting spread is known-good, this
    /// returns the `step` to use at a *different* `newDecay` that reproduces the exact same
    /// steady-state std. Used to shorten the jitter's autocorrelation time (see
    /// `syntheticTypingStream`'s doc comment) without also — as an unintended side effect —
    /// shrinking how far the walk actually wanders.
    static func amplitudePreservingStep(referenceStep: Double, referenceDecay: Double, newDecay: Double) -> Double {
        let referenceStd = referenceStep / (3 * (1 - referenceDecay * referenceDecay)).squareRoot()
        return referenceStd * (3 * (1 - newDecay * newDecay)).squareRoot()
    }

    // MARK: - Synthetic typing stream (60 s @ 15 Hz)

    /// ~15 Hz, 60 s → 900 frames jittering `SyntheticHand.typingHand`.
    ///
    /// Per joint, per axis, an AR(1) mean-reverting random walk: `offset = offset * decay +
    /// noise`, with `noise` drawn uniformly from `[-step, step]` and `decay = 0.4`.
    ///
    /// **History, corrected.** The first version used `decay = 0.85`, `step = 0.03` (the ±0.03
    /// per-frame cap originally asked for). At `decay = 0.85` the walk's autocorrelation time
    /// (`1/(1-decay) ≈ 6.7` frames `≈ 0.44s`) happened to land almost exactly on
    /// `ArbitrationTuning.clutchHold` (0.4s default), so whenever noise pushed the thumb far
    /// enough from the index tip to read as "not pinched," the same slow-moving noise tended to
    /// *stay* there for roughly a clutch-hold's worth of frames — a false arm, confirmed at
    /// t≈53.1s in the first run of this suite (single default seed). The fix at the time lowered
    /// `decay` to `0.4` (autocorrelation ≈1.7 frames ≈0.11s, well below the clutch hold) but kept
    /// `step = 0.03` unchanged, on the claimed grounds that this preserved "a comparable
    /// steady-state spread." **That claim was wrong** — steady-state std scales as
    /// `step / sqrt(1 - decay^2)`, so dropping decay from 0.85 to 0.4 at a fixed step shrank the
    /// std from ≈0.033 to ≈0.019 (≈43% smaller). An 11-seed sweep at those (wrong) parameters
    /// found 0/11 seeds coming within 2 frames of the arming boundary — the suite had gone quiet
    /// not because typing jitter is safe, but because the generator's amplitude had been
    /// accidentally muted. The *same* sweep at `decay = 0.85` (correct amplitude, slow
    /// autocorrelation) found 4/11 seeds crossing the 7-consecutive-frame arm threshold.
    ///
    /// The honest fix keeps the shorter, more realistic autocorrelation (a hand actively typing
    /// changes its instantaneous finger configuration many times over 400ms; it doesn't hold
    /// quasi-static that long) but **compensates the step size** via `amplitudePreservingStep` so
    /// the steady-state std matches the original `decay=0.85, step=0.03` process (~0.033
    /// normalized) exactly. That does mean the effective per-frame step is now larger than the
    /// original ±0.03 ask (~±0.052) — that trade is deliberate and necessary: decorrelating faster
    /// while preserving amplitude *requires* a bigger per-step kick, by the formula above. Capping
    /// the step at 0.03 while also demanding fast decorrelation is mathematically impossible to
    /// combine with "same real-world spread," so the amplitude constraint (matching genuine
    /// finger-jitter magnitude) wins over the literal step-size number.
    ///
    /// ~10% of frames additionally drop 2-4 random joints (simulating brief tracking loss), and
    /// every 4 s the stream interleaves a ~0.6 s triangular "half-open drift" — hand relaxing or
    /// lifting slightly off the keys — by blending a fraction of the way toward an openPalm-ish
    /// pose and back. The drift only ever moves *toward* open, never toward a fist.
    static func syntheticTypingStream(seed: UInt64 = 0x7E17_1116_1DEA_1001) -> [LandmarkFrame] {
        var rng = SeededGenerator(seed: seed)
        let dt: TimeInterval = 1.0 / 15.0
        let frameCount = 900
        let decay = 0.4
        let step = Self.amplitudePreservingStep(referenceStep: 0.03, referenceDecay: 0.85, newDecay: decay)

        let baseFrame = SyntheticHand.typingHand()
        let openFrame = SyntheticHand.openPalm()

        var offsetX: [HandJoint: Double] = [:]
        var offsetY: [HandJoint: Double] = [:]

        var frames: [LandmarkFrame] = []
        frames.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let t = TimeInterval(i) * dt

            let driftPeriod = 4.0
            let driftDuration = 0.6
            let phase = t.truncatingRemainder(dividingBy: driftPeriod)
            var driftFactor = 0.0
            if phase < driftDuration {
                let half = driftDuration / 2
                driftFactor = phase < half ? phase / half : (driftDuration - phase) / half
            }
            let openBlend = driftFactor * 0.3 // never more than 30% of the way to fully open

            var frameJoints: [HandJoint: JointPoint] = [:]
            for joint in HandJoint.allCases {
                guard let base = baseFrame.point(joint) else { continue }
                let openPoint = openFrame.point(joint) ?? base

                let dx = (offsetX[joint] ?? 0) * decay + rng.nextSigned() * step
                let dy = (offsetY[joint] ?? 0) * decay + rng.nextSigned() * step
                offsetX[joint] = dx
                offsetY[joint] = dy

                let blendedX = base.x + (openPoint.x - base.x) * openBlend
                let blendedY = base.y + (openPoint.y - base.y) * openBlend

                let x = min(max(blendedX + dx, 0), 1)
                let y = min(max(blendedY + dy, 0), 1)
                frameJoints[joint] = JointPoint(x: x, y: y, confidence: base.confidence)
            }

            // ~10% of frames lose 2-4 random joints (tracking dropout).
            if rng.nextUnit() < 0.10 {
                let dropCount = min(2 + Int(rng.nextUnit() * 3), frameJoints.count) // 2...4
                var remaining = HandJoint.allCases.filter { frameJoints[$0] != nil }
                for _ in 0..<dropCount {
                    guard !remaining.isEmpty else { break }
                    let idx = min(Int(rng.nextUnit() * Double(remaining.count)), remaining.count - 1)
                    let victim = remaining.remove(at: idx)
                    frameJoints.removeValue(forKey: victim)
                }
            }

            frames.append(LandmarkFrame(timestamp: t, joints: frameJoints, handedness: .right))
        }

        return frames
    }

    // MARK: - Synthetic conversation stream (30 s @ 15 Hz)

    /// ~15 Hz, 30 s → 450 frames of larger, conversational hand motion.
    ///
    /// Openness oscillates smoothly between `SyntheticHand.typingHand` (0) and
    /// `SyntheticHand.openPalm` (1) on a 6 s sine cycle — a fully open palm passing through is
    /// expected and harmless while disarmed (`.openPalm` only matters as a disarm signal while
    /// *armed*). On top of that, the whole hand translates: a slow ~11-13 s pan across the frame
    /// plus a faster ~1.3-1.7 s wave-like oscillation, both applied rigidly to every joint. A
    /// smaller AR(1) per-joint jitter (same mean-reverting model as the typing stream, smaller
    /// reference amplitude) rides on top for realism. Same `decay = 0.4` +
    /// `amplitudePreservingStep` treatment as `syntheticTypingStream` — see its doc comment for
    /// the derivation and the amplitude-shrinking mistake it corrects; here the reference process
    /// is `decay=0.85, step=0.015` (this stream's original, smaller jitter amplitude) rather than
    /// the typing stream's `0.03`.
    static func syntheticConversationStream(seed: UInt64 = 0xC0FF_EE00_1234_5678) -> [LandmarkFrame] {
        var rng = SeededGenerator(seed: seed)
        let dt: TimeInterval = 1.0 / 15.0
        let frameCount = 450
        let decay = 0.4
        let jitterStep = Self.amplitudePreservingStep(referenceStep: 0.015, referenceDecay: 0.85, newDecay: decay)

        let closedFrame = SyntheticHand.typingHand()
        let openFrame = SyntheticHand.openPalm()

        var offsetX: [HandJoint: Double] = [:]
        var offsetY: [HandJoint: Double] = [:]

        var frames: [LandmarkFrame] = []
        frames.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let t = TimeInterval(i) * dt

            let opennessPeriod = 6.0
            let openBlend = (sin(2 * Double.pi * t / opennessPeriod) + 1) / 2

            let panX = 0.12 * sin(2 * Double.pi * t / 11.0)
            let panY = 0.05 * sin(2 * Double.pi * t / 13.0)
            let waveX = 0.04 * sin(2 * Double.pi * t / 1.3)
            let waveY = 0.02 * sin(2 * Double.pi * t / 1.7)
            let translateX = panX + waveX
            let translateY = panY + waveY

            var frameJoints: [HandJoint: JointPoint] = [:]
            for joint in HandJoint.allCases {
                guard let closed = closedFrame.point(joint), let open = openFrame.point(joint) else { continue }

                let dx = (offsetX[joint] ?? 0) * decay + rng.nextSigned() * jitterStep
                let dy = (offsetY[joint] ?? 0) * decay + rng.nextSigned() * jitterStep
                offsetX[joint] = dx
                offsetY[joint] = dy

                let blendedX = closed.x + (open.x - closed.x) * openBlend
                let blendedY = closed.y + (open.y - closed.y) * openBlend

                let x = min(max(blendedX + translateX + dx, 0), 1)
                let y = min(max(blendedY + translateY + dy, 0), 1)
                frameJoints[joint] = JointPoint(x: x, y: y, confidence: closed.confidence)
            }

            frames.append(LandmarkFrame(timestamp: t, joints: frameJoints, handedness: .right))
        }

        return frames
    }

    // MARK: - Pre-armed helper (for the informational leg only)

    /// An `ArbitrationEngine` already `.armed` via a synthetic `looseFist` hold past
    /// `clutchHold`, and the timestamp of the last arming frame. Callers should time-shift replay
    /// frames to start just after that timestamp (see `timeShifted`).
    static func preArmedEngine() -> (engine: ArbitrationEngine, lastArmingTime: TimeInterval) {
        let engine = ArbitrationEngine()
        let classifier = StaticPoseClassifier()
        let dt: TimeInterval = 1.0 / 15.0
        let armingFrames = (0...7).map { SyntheticHand.looseFist(t: TimeInterval($0) * dt) }
        var lastTime: TimeInterval = 0
        for frame in armingFrames {
            _ = engine.ingest(classifier.classify(frame), at: frame.timestamp)
            lastTime = frame.timestamp
        }
        return (engine, lastTime)
    }

    /// Shifts `frames` so the first one lands 0.05 s after `time` — used to splice a stream right
    /// after a synthetic arming preamble without the stream needing to know about it.
    static func timeShifted(_ frames: [LandmarkFrame], toStartAfter time: TimeInterval) -> [LandmarkFrame] {
        guard let first = frames.first?.timestamp else { return frames }
        let offset = (time + 0.05) - first
        return frames.map { LandmarkFrame(timestamp: $0.timestamp + offset, joints: $0.joints, handedness: $0.handedness) }
    }

    // MARK: - Recorded-fixture path (Tests/Fixtures/typing-negative*.json, conversation-negative*.json)

    /// Mirrors `FixtureReplayTests.fixturesDirectory`: resolved relative to this source file so it
    /// works regardless of the current working directory the test runner uses.
    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // NegativeSuiteTests.swift
        .deletingLastPathComponent() // TacitCoreTests/
        .appendingPathComponent("Fixtures")

    /// Every file in `fixturesDirectory` whose name starts with `prefix`, sorted by name. Empty
    /// (never a failure) if the directory doesn't exist yet or nothing matches.
    static func fixtureURLs(prefix: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: fixturesDirectory, includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadFrames(url: URL) -> [LandmarkFrame]? {
        guard let data = try? Data(contentsOf: url),
              let frames = try? FixtureCodec.decode(data),
              !frames.isEmpty else {
            print("[NegativeSuiteTests] fixture \(url.lastPathComponent) is unreadable or empty — skipping.")
            return nil
        }
        return frames
    }

    // MARK: - Seed sweep (a single seed can get lucky; a fixed panel can't)

    /// 11 fixed, arbitrary-but-deterministic seeds. Every disarmed assertion below runs across
    /// all of them (Swift Testing parameterized `@Test(arguments:)`) instead of trusting one
    /// hand-picked seed — the exact gap that let the amplitude-shrinking generator bug (see
    /// `syntheticTypingStream`'s doc comment) go undetected: at the wrong parameters 0/11 seeds
    /// came within 2 frames of the arm threshold, while the amplitude-corrected generator below
    /// is judged by the same 11-seed panel.
    static let sweepSeeds: [UInt64] = [
        0x7E17_1116_1DEA_1001,
        0x0000_0000_0000_0001,
        0x1234_5678_9ABC_DEF0,
        0xDEAD_BEEF_CAFE_F00D,
        0x9E37_79B9_7F4A_7C15,
        0xFFFF_FFFF_FFFF_FFFF,
        0x0BAD_F00D_600D_C0DE,
        0x5EED_5EED_5EED_5EED,
        0xA5A5_A5A5_5A5A_5A5A,
        0x1111_2222_3333_4444,
        0x8888_7777_6666_5555,
    ]

    // MARK: - Disarmed assertions: zero events, engine never reaches .armed, across the seed sweep

    @Test(arguments: Self.sweepSeeds)
    func syntheticTypingStreamNeverFiresOrArmsWhileDisarmed(seed: UInt64) {
        let frames = Self.syntheticTypingStream(seed: seed)
        let engine = ArbitrationEngine()
        let result = Self.replayThroughFullChain(frames: frames, engine: engine)
        #expect(result.events.isEmpty, "seed 0x\(String(seed, radix: 16)) fired an event while disarmed")
        #expect(!result.everArmed, "seed 0x\(String(seed, radix: 16)) armed the clutch while disarmed")
    }

    @Test(arguments: Self.sweepSeeds)
    func syntheticConversationStreamNeverFiresOrArmsWhileDisarmed(seed: UInt64) {
        let frames = Self.syntheticConversationStream(seed: seed)
        let engine = ArbitrationEngine()
        let result = Self.replayThroughFullChain(frames: frames, engine: engine)
        #expect(result.events.isEmpty, "seed 0x\(String(seed, radix: 16)) fired an event while disarmed")
        #expect(!result.everArmed, "seed 0x\(String(seed, radix: 16)) armed the clutch while disarmed")
    }

    /// Non-failing diagnostic: for every sweep seed, prints whether the stream ever armed/fired
    /// and the closest it ever came to arming (`maxArmingProgress`, 0...1 — 1.0 means it armed).
    /// This is the data behind the per-seed table in the task report; the pass/fail judgment
    /// itself lives in the two `@Test(arguments:)` functions above.
    @Test func seedSweepDiagnostics() {
        for seed in Self.sweepSeeds {
            for (label, frames) in [
                ("typing", Self.syntheticTypingStream(seed: seed)),
                ("conversation", Self.syntheticConversationStream(seed: seed)),
            ] {
                let classifier = StaticPoseClassifier()
                var tapDetector = PinchTapDetector()
                var swipeDetector = ThumbSwipeDetector()
                var handSwipeDetector = HandSwipeDetector()
                var fistToOpenDetector = FistToOpenDetector()
                var wristRotateDetector = WristRotateDetector()
                var twoFingerScrollDetector = TwoFingerScrollDetector()
                let engine = ArbitrationEngine()
                var everArmed = false
                var everFired = false
                var maxProgress = 0.0
                for frame in frames {
                    let poseCandidate = classifier.classify(frame)
                    let staticEvent = engine.ingest(poseCandidate, at: frame.timestamp)
                    let momentaryCandidate = tapDetector.ingest(frame)
                        ?? swipeDetector.ingest(frame)
                        ?? handSwipeDetector.ingest(frame)
                        ?? fistToOpenDetector.ingest(frame)
                        ?? wristRotateDetector.ingest(frame)
                        ?? twoFingerScrollDetector.ingest(frame)
                    let preDebouncedEvent = momentaryCandidate.flatMap { engine.ingestPreDebounced($0, at: frame.timestamp) }
                    if (preDebouncedEvent ?? staticEvent) != nil { everFired = true }
                    switch engine.state {
                    case .armed: everArmed = true
                    case .arming(let progress): maxProgress = max(maxProgress, progress)
                    case .disarmed: break
                    }
                }
                print("[NegativeSuiteTests] sweep seed=0x\(String(seed, radix: 16)) stream=\(label): everArmed=\(everArmed) everFired=\(everFired) maxArmingProgress=\(String(format: "%.3f", maxProgress))")
            }
        }
    }

    @Test func recordedTypingNegativeFixturesNeverFireOrArmWhileDisarmed() {
        let urls = Self.fixtureURLs(prefix: "typing-negative")
        guard !urls.isEmpty else {
            print("[NegativeSuiteTests] no typing-negative* fixture found in \(Self.fixturesDirectory.path) — skipping recorded leg (synthetic coverage still ran).")
            return
        }
        for url in urls {
            guard let frames = Self.loadFrames(url: url) else { continue }
            let engine = ArbitrationEngine()
            let result = Self.replayThroughFullChain(frames: frames, engine: engine)
            #expect(result.events.isEmpty, "recorded fixture \(url.lastPathComponent) fired an event while disarmed")
            #expect(!result.everArmed, "recorded fixture \(url.lastPathComponent) armed the clutch while disarmed")
        }
    }

    @Test func recordedConversationNegativeFixturesNeverFireOrArmWhileDisarmed() {
        let urls = Self.fixtureURLs(prefix: "conversation-negative")
        guard !urls.isEmpty else {
            print("[NegativeSuiteTests] no conversation-negative* fixture found in \(Self.fixturesDirectory.path) — skipping recorded leg (synthetic coverage still ran).")
            return
        }
        for url in urls {
            guard let frames = Self.loadFrames(url: url) else { continue }
            let engine = ArbitrationEngine()
            let result = Self.replayThroughFullChain(frames: frames, engine: engine)
            #expect(result.events.isEmpty, "recorded fixture \(url.lastPathComponent) fired an event while disarmed")
            #expect(!result.everArmed, "recorded fixture \(url.lastPathComponent) armed the clutch while disarmed")
        }
    }

    // MARK: - Pre-armed informational leg (non-failing; for tuning)

    @Test func preArmedSyntheticStreamsInformationalEventCounts() {
        let typingFrames = Self.syntheticTypingStream()
        let (typingEngine, typingArmTime) = Self.preArmedEngine()
        let shiftedTyping = Self.timeShifted(typingFrames, toStartAfter: typingArmTime)
        let typingResult = Self.replayThroughFullChain(frames: shiftedTyping, engine: typingEngine)
        print("[NegativeSuiteTests] pre-armed synthetic typing stream (60s): \(typingResult.events.count) event(s) fired (informational).")

        let conversationFrames = Self.syntheticConversationStream()
        let (conversationEngine, conversationArmTime) = Self.preArmedEngine()
        let shiftedConversation = Self.timeShifted(conversationFrames, toStartAfter: conversationArmTime)
        let conversationResult = Self.replayThroughFullChain(frames: shiftedConversation, engine: conversationEngine)
        print("[NegativeSuiteTests] pre-armed synthetic conversation stream (30s): \(conversationResult.events.count) event(s) fired (informational).")
    }

    @Test func preArmedRecordedNegativeFixturesInformationalEventCounts() {
        let urls = Self.fixtureURLs(prefix: "typing-negative") + Self.fixtureURLs(prefix: "conversation-negative")
        guard !urls.isEmpty else {
            print("[NegativeSuiteTests] no recorded negative fixtures found — skipping pre-armed informational leg for recordings.")
            return
        }
        for url in urls {
            guard let frames = Self.loadFrames(url: url) else { continue }
            let (engine, armTime) = Self.preArmedEngine()
            let shifted = Self.timeShifted(frames, toStartAfter: armTime)
            let result = Self.replayThroughFullChain(frames: shifted, engine: engine)
            print("[NegativeSuiteTests] pre-armed recorded fixture \(url.lastPathComponent): \(result.events.count) event(s) fired (informational).")
        }
    }
}
