import Foundation
import Testing
@testable import TacitCore

// MARK: 1. The very first call always runs, regardless of `now`.

@Test func firstCallAlwaysRuns() {
    var throttle = InferenceThrottle()
    #expect(throttle.shouldRun(at: 0) == true)
}

// MARK: 2. A call 0.03s after the last run is inside the 1/15s (~0.0667s) window: suppressed.

@Test func callWithinMinIntervalIsSuppressed() {
    var throttle = InferenceThrottle()
    #expect(throttle.shouldRun(at: 0) == true)
    #expect(throttle.shouldRun(at: 0.03) == false)
}

// MARK: 3. A call 0.07s after the *last run* (not the suppressed call) is past the window: runs.

@Test func callPastMinIntervalFromLastRunRuns() {
    var throttle = InferenceThrottle()
    #expect(throttle.shouldRun(at: 0) == true)
    #expect(throttle.shouldRun(at: 0.03) == false)
    #expect(throttle.shouldRun(at: 0.07) == true)
}

// MARK: 4. A call landing exactly on the boundary (now == last run + minInterval) runs.

@Test func exactBoundaryCallRuns() {
    let minInterval = 1.0 / 15.0
    var throttle = InferenceThrottle(minInterval: minInterval)
    #expect(throttle.shouldRun(at: 0) == true)
    #expect(throttle.shouldRun(at: minInterval) == true)
}
