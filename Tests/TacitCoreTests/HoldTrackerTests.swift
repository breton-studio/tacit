import Foundation
import Testing
@testable import TacitCore

private let holdables: Set<GestureID> = [.indexPoint, .thumbsUp, .victory]

private func candidate(_ gesture: GestureID?, at t: TimeInterval, conf: Double = 0.9) -> GestureCandidate? {
    gesture.map { GestureCandidate(gesture: $0, confidence: conf, timestamp: t) }
}

// MARK: 1. began after fire+persist

@Test func beginsWhenHoldableGestureFiresAndPosePersists() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    let event = tracker.ingest(fired: fired, candidate: candidate(.indexPoint, at: 1.0), at: 1.0)
    #expect(event == GestureHoldEvent(gesture: .indexPoint, phase: .began, timestamp: 1.0))
}

// MARK: 2. not began without fire

@Test func noBeginWithoutAFire() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let event = tracker.ingest(fired: nil, candidate: candidate(.indexPoint, at: 1.0), at: 1.0)
    #expect(event == nil)
}

@Test func noBeginWhenFireHasNoPersistingCandidate() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    // Candidate absent on the firing frame: the pose already isn't there any more.
    let event = tracker.ingest(fired: fired, candidate: nil, at: 1.0)
    #expect(event == nil)
}

@Test func noBeginWhenFiredCandidateMismatch() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    let event = tracker.ingest(fired: fired, candidate: candidate(.thumbsUp, at: 1.0), at: 1.0)
    #expect(event == nil)
}

// MARK: 3. non-holdable fires ignored

@Test func nonHoldableGestureFireNeverBegins() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .thumbIndexTap, timestamp: 1.0)
    let event = tracker.ingest(fired: fired, candidate: candidate(.thumbIndexTap, at: 1.0), at: 1.0)
    #expect(event == nil)
}

// MARK: 4. ended after 2 missing frames; single-missing-frame forgiven

@Test func endsAfterTwoConsecutiveMissingFrames() {
    var tracker = HoldTracker(holdableGestures: holdables, releaseAfterMissingFrames: 2)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    let began = tracker.ingest(fired: fired, candidate: candidate(.indexPoint, at: 1.0), at: 1.0)
    #expect(began?.phase == .began)

    // First missing frame: forgiven, no event.
    let miss1 = tracker.ingest(fired: nil, candidate: nil, at: 1.1)
    #expect(miss1 == nil)

    // Second consecutive missing frame: ends the hold.
    let miss2 = tracker.ingest(fired: nil, candidate: nil, at: 1.2)
    #expect(miss2 == GestureHoldEvent(gesture: .indexPoint, phase: .ended, timestamp: 1.2))
}

@Test func singleMissingFrameIsForgivenIfPoseReturns() {
    var tracker = HoldTracker(holdableGestures: holdables, releaseAfterMissingFrames: 2)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    _ = tracker.ingest(fired: fired, candidate: candidate(.indexPoint, at: 1.0), at: 1.0)

    let miss = tracker.ingest(fired: nil, candidate: nil, at: 1.1)
    #expect(miss == nil)

    // Pose returns before the second consecutive miss: hold continues, no event.
    let recovered = tracker.ingest(fired: nil, candidate: candidate(.indexPoint, at: 1.2), at: 1.2)
    #expect(recovered == nil)

    // Confirm the hold is still alive by requiring TWO more fresh consecutive misses to end it.
    let miss1 = tracker.ingest(fired: nil, candidate: nil, at: 1.3)
    #expect(miss1 == nil)
    let miss2 = tracker.ingest(fired: nil, candidate: nil, at: 1.4)
    #expect(miss2?.phase == .ended)
}

// MARK: 5. reset() ends an active hold

@Test func resetEndsAnActiveHold() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .thumbsUp, timestamp: 2.0)
    _ = tracker.ingest(fired: fired, candidate: candidate(.thumbsUp, at: 2.0), at: 2.0)

    let ended = tracker.reset()
    #expect(ended == GestureHoldEvent(gesture: .thumbsUp, phase: .ended, timestamp: 2.0))
}

@Test func resetIsNilWhenNothingIsHeld() {
    var tracker = HoldTracker(holdableGestures: holdables)
    #expect(tracker.reset() == nil)
}

@Test func resetIsIdempotent() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .victory, timestamp: 3.0)
    _ = tracker.ingest(fired: fired, candidate: candidate(.victory, at: 3.0), at: 3.0)
    #expect(tracker.reset() != nil)
    #expect(tracker.reset() == nil)
}

// MARK: 6. second fire while holding ignored

@Test func secondFireWhileHoldingIsIgnored() {
    var tracker = HoldTracker(holdableGestures: holdables)
    let fired = GestureEvent(gesture: .indexPoint, timestamp: 1.0)
    let began = tracker.ingest(fired: fired, candidate: candidate(.indexPoint, at: 1.0), at: 1.0)
    #expect(began?.phase == .began)

    // A re-fire of the same gesture (e.g. cooldown elapsed) mid-hold: no new began, no event at
    // all — the candidate still matches, so the hold just continues.
    let refired = GestureEvent(gesture: .indexPoint, timestamp: 1.1)
    let event = tracker.ingest(fired: refired, candidate: candidate(.indexPoint, at: 1.1), at: 1.1)
    #expect(event == nil)

    // A fire of a DIFFERENT holdable gesture mid-hold must not redirect/restart the hold either.
    let otherFire = GestureEvent(gesture: .victory, timestamp: 1.2)
    let event2 = tracker.ingest(fired: otherFire, candidate: candidate(.indexPoint, at: 1.2), at: 1.2)
    #expect(event2 == nil)

    // Only one hold is active: ending it must report the ORIGINAL gesture, not the interloper.
    let ended = tracker.reset()
    #expect(ended == GestureHoldEvent(gesture: .indexPoint, phase: .ended, timestamp: 1.2))
}
