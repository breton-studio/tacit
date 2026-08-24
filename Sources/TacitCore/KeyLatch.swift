import Foundation

/// The key a `.toggleKeystroke` fire has latched down, and which gesture did it.
public struct LatchedKey: Equatable, Sendable {
    public let gesture: GestureID
    public let chord: KeyChord

    public init(gesture: GestureID, chord: KeyChord) {
        self.gesture = gesture
        self.chord = chord
    }
}

/// What the caller must post after a `KeyLatch.toggle` — the latch itself never touches the
/// keyboard. Ordering inside `.swapped` matters: release the old chord BEFORE engaging the new
/// one, so at most one latched key is ever down.
public enum LatchTransition: Equatable, Sendable {
    case engaged(KeyChord)
    case released(KeyChord)
    case swapped(released: KeyChord, engaged: KeyChord)
}

/// Pure state for `.toggleKeystroke`: at most ONE chord is latched at a time. `toggle` with the
/// currently latched chord releases it (regardless of which gesture asks); `toggle` with a
/// different chord swaps. `release()` is the forced path every safety exit uses (capture stopped,
/// app quit, binding changed, popover "Release" row) — it hands back the chord to key-up, exactly
/// once, or `nil` when nothing was latched. Mirrors `HoldTracker`'s design: the engine owns the
/// key posting; this type only decides.
public struct KeyLatch: Equatable, Sendable {
    public private(set) var active: LatchedKey?

    public init() {}

    public mutating func toggle(gesture: GestureID, chord: KeyChord) -> LatchTransition {
        guard let current = active else {
            active = LatchedKey(gesture: gesture, chord: chord)
            return .engaged(chord)
        }
        if current.chord == chord {
            active = nil
            return .released(chord)
        }
        active = LatchedKey(gesture: gesture, chord: chord)
        return .swapped(released: current.chord, engaged: chord)
    }

    public mutating func release() -> KeyChord? {
        defer { active = nil }
        return active?.chord
    }

    public func isLatched(_ chord: KeyChord) -> Bool {
        active?.chord == chord
    }
}
