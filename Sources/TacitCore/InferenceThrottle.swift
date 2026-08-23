import Foundation

/// Caps how often inference is allowed to run, given a stream of frame timestamps.
///
/// `InferenceThrottle` holds zero wall-clock state of its own — every decision is a pure
/// function of the `now` timestamp passed in and the timestamp of the last accepted call, so
/// it is fully deterministic under fixture/replay testing (no `Date()` inside).
public struct InferenceThrottle: Sendable {
    private let minInterval: TimeInterval
    private var lastRunAt: TimeInterval?

    public init(minInterval: TimeInterval = 1.0 / 15.0) {
        self.minInterval = minInterval
    }

    /// Returns `true` if inference should run for a frame arriving at `now`, and — only in that
    /// case — records `now` as the new "last run" timestamp future calls are measured against.
    public mutating func shouldRun(at now: TimeInterval) -> Bool {
        if let lastRunAt, now - lastRunAt < minInterval {
            return false
        }
        lastRunAt = now
        return true
    }
}
