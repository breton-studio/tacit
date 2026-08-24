import Foundation
import Testing
@testable import TacitCore

private let threeApps = ["com.a", "com.b", "com.c"]

private func snapshotCalls(_ items: [String], _ counter: Counter) -> () -> [String] {
    { counter.count += 1; return items }
}

/// A tiny mutable box so closures passed into `flip(_:snapshot:now:)` can record how many times
/// they were actually invoked — `AppSwitchRing` itself stays a plain `Equatable` value type with
/// no call-count bookkeeping of its own.
private final class Counter: @unchecked Sendable {
    var count = 0
}

@Test func firstFlipNextReturnsSecondItem() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let result = ring.flip(.next, snapshot: { threeApps }, now: 0)
    #expect(result == "com.b")
    #expect(ring.items == threeApps)
    #expect(ring.index == 1)
}

@Test func twoConsecutiveNextFlipsLandOnThirdItem() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    _ = ring.flip(.next, snapshot: { threeApps }, now: 0)
    let result = ring.flip(.next, snapshot: { threeApps }, now: 0.1)
    #expect(result == "com.c")
    #expect(ring.index == 2)
}

@Test func nextThenPreviousReturnsToFirstItem() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    _ = ring.flip(.next, snapshot: { threeApps }, now: 0)
    let result = ring.flip(.previous, snapshot: { threeApps }, now: 0.1)
    #expect(result == "com.a")
    #expect(ring.index == 0)
}

@Test func nextClampsAtTheEndOfTheList() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    _ = ring.flip(.next, snapshot: { threeApps }, now: 0)
    _ = ring.flip(.next, snapshot: { threeApps }, now: 0.1)
    let result = ring.flip(.next, snapshot: { threeApps }, now: 0.2) // already at index 2
    #expect(result == "com.c")
    #expect(ring.index == 2)
}

@Test func previousClampsAtTheFrontOfTheList() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let result = ring.flip(.previous, snapshot: { threeApps }, now: 0) // fresh session starts at index 0
    #expect(result == "com.a")
    #expect(ring.index == 0)
}

@Test func timeoutExpiryReSnapshotsAndResetsIndex() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let counter = Counter()
    _ = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 0)
    #expect(counter.count == 1)
    #expect(ring.index == 1)

    // 5s later — past the 4s timeout — the next flip re-snapshots and restarts at index 0, then
    // steps once from there.
    let result = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 5)
    #expect(counter.count == 2)
    #expect(result == "com.b")
    #expect(ring.index == 1)
}

@Test func flipWithinTimeoutDoesNotReSnapshot() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let counter = Counter()
    _ = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 0)
    _ = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 3.9)
    #expect(counter.count == 1)
}

@Test func invalidateForcesReSnapshotOnNextFlip() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let counter = Counter()
    _ = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 0)
    ring.invalidate()
    let result = ring.flip(.next, snapshot: snapshotCalls(threeApps, counter), now: 0.5) // well within timeout
    #expect(counter.count == 2)
    #expect(result == "com.b") // fresh session, index reset to 0, then stepped once
    #expect(ring.index == 1)
}

@Test func emptySnapshotReturnsNil() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let result = ring.flip(.next, snapshot: { [] }, now: 0)
    #expect(result == nil)
    #expect(ring.items.isEmpty)
}

@Test func singleItemSnapshotReturnsItAndStaysOnRepeatedFlips() {
    var ring = AppSwitchRing(sessionTimeout: 4.0)
    let first = ring.flip(.next, snapshot: { ["com.only"] }, now: 0)
    #expect(first == "com.only")
    let second = ring.flip(.next, snapshot: { ["com.only"] }, now: 0.1)
    #expect(second == "com.only")
    let third = ring.flip(.previous, snapshot: { ["com.only"] }, now: 0.2)
    #expect(third == "com.only")
}
