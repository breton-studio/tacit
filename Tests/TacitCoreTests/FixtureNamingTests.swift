import Foundation
import Testing
@testable import TacitCore

private let utc = TimeZone(identifier: "UTC")!

/// A fixed instant — 2026-08-23 14:30:05 UTC — used across these tests so the formatted
/// timestamp is deterministic regardless of the machine (or its local time zone) running them.
private let fixedDate: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 23
    components.hour = 14
    components.minute = 30
    components.second = 5
    return calendar.date(from: components)!
}()

@Test func filenameSanitizesLabelToLowercaseAlphanumericDashes() {
    let result = FixtureNaming.filename(label: "Pinch Index!", date: fixedDate, timeZone: utc)
    #expect(result == "pinch-index-20260823-143005.json")
}

@Test func filenameDateFormattingIsDeterministicForAFixedTimeZone() {
    let result = FixtureNaming.filename(label: "clip", date: fixedDate, timeZone: utc)
    #expect(result == "clip-20260823-143005.json")
}

@Test func filenameFallsBackToFixtureForAnEmptyLabel() {
    let result = FixtureNaming.filename(label: "", date: fixedDate, timeZone: utc)
    #expect(result == "fixture-20260823-143005.json")
}

@Test func filenameFallsBackToFixtureWhenLabelHasNoAlphanumerics() {
    let result = FixtureNaming.filename(label: "!!!", date: fixedDate, timeZone: utc)
    #expect(result == "fixture-20260823-143005.json")
}

@Test func filenameCollapsesRunsOfSeparatorsAndTrimsEdges() {
    let result = FixtureNaming.filename(label: "  -- Thumb__Index -- ", date: fixedDate, timeZone: utc)
    #expect(result == "thumb-index-20260823-143005.json")
}
