import Testing
@testable import TacitCore

private let fn = KeyChord(keyCode: 63, modifiers: [])
private let cmdSpace = KeyChord(keyCode: 49, modifiers: [.command])

@Test func freshLatchHasNothingActive() {
    let latch = KeyLatch()
    #expect(latch.active == nil)
    #expect(latch.isLatched(fn) == false)
    var mutable = latch
    #expect(mutable.release() == nil)
}

@Test func firstToggleEngagesAndRecordsGestureAndChord() {
    var latch = KeyLatch()
    #expect(latch.toggle(gesture: .thumbRingPinkyTap, chord: fn) == .engaged(fn))
    #expect(latch.active == LatchedKey(gesture: .thumbRingPinkyTap, chord: fn))
    #expect(latch.isLatched(fn) == true)
    #expect(latch.isLatched(cmdSpace) == false)
}

@Test func secondToggleOfSameChordReleases() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .thumbRingPinkyTap, chord: fn) == .released(fn))
    #expect(latch.active == nil)
}

@Test func sameChordFromADifferentGestureStillReleases() {
    // Two gestures bound to Toggle Fn are one latch: either can end it.
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .victory, chord: fn) == .released(fn))
    #expect(latch.active == nil)
}

@Test func toggleOfADifferentChordSwapsReleasingTheOldFirst() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.toggle(gesture: .victory, chord: cmdSpace) == .swapped(released: fn, engaged: cmdSpace))
    #expect(latch.active == LatchedKey(gesture: .victory, chord: cmdSpace))
}

@Test func releaseReturnsTheLatchedChordExactlyOnce() {
    var latch = KeyLatch()
    _ = latch.toggle(gesture: .thumbRingPinkyTap, chord: fn)
    #expect(latch.release() == fn)
    #expect(latch.release() == nil)
    #expect(latch.active == nil)
}
