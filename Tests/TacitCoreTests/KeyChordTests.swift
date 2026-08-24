import Foundation
import Testing
@testable import TacitCore

@Test func displayRendersCommandCAsCommandC() {
    let chord = KeyChord(keyCode: 8, modifiers: [.command])
    #expect(chord.display == "⌘C")
}

@Test func displayOrdersModifiersControlOptionShiftCommand() {
    let chord = KeyChord(keyCode: 6, modifiers: [.command, .shift])
    #expect(chord.display == "⇧⌘Z")
}

@Test func displayOrdersAllFourModifiersControlOptionShiftCommand() {
    let chord = KeyChord(keyCode: 8, modifiers: [.command, .shift, .option, .control])
    #expect(chord.display == "⌃⌥⇧⌘C")
}

@Test func displayRendersDefaultBindingKeyCodes() {
    #expect(KeyChord(keyCode: 8, modifiers: []).display == "C")
    #expect(KeyChord(keyCode: 9, modifiers: []).display == "V")
    #expect(KeyChord(keyCode: 6, modifiers: []).display == "Z")
}

@Test func displayRendersNamedNonLetterKeys() {
    #expect(KeyChord(keyCode: 36, modifiers: []).display == "Return")
    #expect(KeyChord(keyCode: 48, modifiers: []).display == "Tab")
    #expect(KeyChord(keyCode: 49, modifiers: []).display == "Space")
    #expect(KeyChord(keyCode: 51, modifiers: []).display == "Delete")
    #expect(KeyChord(keyCode: 53, modifiers: []).display == "Escape")
}

@Test func displayRendersArrowKeys() {
    #expect(KeyChord(keyCode: 123, modifiers: []).display == "Left")
    #expect(KeyChord(keyCode: 124, modifiers: []).display == "Right")
    #expect(KeyChord(keyCode: 125, modifiers: []).display == "Down")
    #expect(KeyChord(keyCode: 126, modifiers: []).display == "Up")
}

/// M3 Task 11: keyCode 63 (`kVK_Function`) is the Fn key — Wispr Flow's stock hold-to-dictate
/// hotkey, and the default `.holdKeystroke` binding for `.indexPoint`
/// (`MappingStore.defaultBindings`). `TacitAction.summary` relies on this rendering as "Fn" via
/// plain `chord.display` rather than a special case, so a summary reads "Hold Fn".
@Test func displayRendersFnKey() {
    #expect(KeyChord(keyCode: 63, modifiers: []).display == "Fn")
}

@Test func displayRendersDigits() {
    #expect(KeyChord(keyCode: 18, modifiers: []).display == "1")
    #expect(KeyChord(keyCode: 29, modifiers: []).display == "0")
}

@Test func displayRendersUnknownKeyCodeAsUppercaseHex() {
    #expect(KeyChord(keyCode: 200, modifiers: []).display == "key 0xC8")
    #expect(KeyChord(keyCode: 96, modifiers: []).display == "key 0x60")
}

@Test func keyChordCodableRoundTrips() throws {
    let chord = KeyChord(keyCode: 6, modifiers: [.command, .shift])
    let data = try JSONEncoder().encode(chord)
    let decoded = try JSONDecoder().decode(KeyChord.self, from: data)
    #expect(decoded == chord)
}

@Test func modifiersCodableRoundTrips() throws {
    let modifiers: KeyChord.Modifiers = [.command, .option]
    let data = try JSONEncoder().encode(modifiers)
    let decoded = try JSONDecoder().decode(KeyChord.Modifiers.self, from: data)
    #expect(decoded == modifiers)
}
