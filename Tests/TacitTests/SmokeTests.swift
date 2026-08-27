import Foundation
import Testing
import TacitCore
@testable import Tacit

/// The ONE smoke test item (d) steps 1–3 ship: proves the injected-`ActionEnvironment` harness
/// works end to end (construct a `TacitEngine` with a spy, drive one gesture fire through it,
/// assert the spy's ordered log). It is deliberately minimal — the seven invariant tests from
/// the review's Finding 2 task breakdown are NOT here; three other agents write those against
/// this same harness. See `Tests/TacitTests/README.md` for the full recipe this test follows.
@MainActor
@Test func engineDispatchesKeystrokeThroughInjectedSpyEnvironment() {
    let spy = ActionEnvironmentSpy()
    let mappingStore = TacitTestSupport.isolatedMappingStore()
    let chord = KeyChord(keyCode: 8, modifiers: [.command]) // ⌘C

    // `.thumbIndexTap` is a plain, non-holdable, non-reserved gesture (not in
    // `TacitEngine.holdableGestures`, not `.looseFist`/`.openPalm`) — a `.keystroke` binding on it
    // reaches `handleFire(_:)`'s synchronous keystroke branch with no hold/toggle detour.
    mappingStore.setBinding(GestureBinding(enabled: true, action: .keystroke(chord)), for: .thumbIndexTap)

    let engine = TacitEngine(actionEnvironment: spy.makeEnvironment(), mappingStore: mappingStore)
    engine.handleFire(GestureEvent(gesture: .thumbIndexTap, timestamp: 0))

    #expect(spy.keyLog == [ActionEnvironmentSpy.KeyOperation(kind: .press, chord: chord)])
    #expect(spy.nonKeyboardLog.isEmpty)
}
