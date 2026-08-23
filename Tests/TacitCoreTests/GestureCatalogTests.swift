import Foundation
import Testing
@testable import TacitCore

@Test func catalogHasAllTwentyOneEntries() {
    #expect(GestureCatalog.entries.count == 21)
}

@Test func catalogEntryIDsAreUnique() {
    let ids = GestureCatalog.entries.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func catalogEntryIDsCoverEveryGestureID() {
    let catalogIDs = Set(GestureCatalog.entries.map(\.id))
    let allIDs = Set(GestureID.allCases)
    #expect(catalogIDs == allIDs)
}

@Test func catalogHasExactlyTwoReservedGestures() {
    let reserved = GestureCatalog.entries.filter(\.isReserved)
    #expect(reserved.count == 2)
    #expect(Set(reserved.map(\.id)) == [.looseFist, .openPalm])
}

@Test func catalogTierPartitionSizesMatchSpec() {
    #expect(GestureCatalog.entries(in: .workhorse).count == 10)
    #expect(GestureCatalog.entries(in: .occasional).count == 8)
    #expect(GestureCatalog.entries(in: .deliberate).count == 3)
}

@Test func everyCatalogEntryHasNonEmptyEditorial() {
    for entry in GestureCatalog.entries {
        #expect(!entry.editorial.isEmpty, "\(entry.id) has empty editorial")
        #expect(!entry.comfort.isEmpty, "\(entry.id) has empty comfort")
        #expect(!entry.falsePositiveRisk.isEmpty, "\(entry.id) has empty falsePositiveRisk")
        #expect(!entry.displayName.isEmpty, "\(entry.id) has empty displayName")
    }
}

@Test func entryForReturnsMatchingEntry() {
    let entry = GestureCatalog.entry(for: .victory)
    #expect(entry.id == .victory)
    #expect(entry.displayName == "Victory")
}

@Test func entriesInTierOnlyReturnsThatTier() {
    for entry in GestureCatalog.entries(in: .occasional) {
        #expect(entry.tier == .occasional)
    }
}

@Test func tierEditorialHasOneLinePerTier() {
    for tier in GestureTier.allCases {
        let note = GestureCatalog.tierEditorial[tier]
        #expect(note != nil)
        #expect(!(note ?? "").isEmpty)
    }
}

@Test func reservedGesturesEditorialExplainsClutchAndDisarm() {
    let fist = GestureCatalog.entry(for: .looseFist)
    let palm = GestureCatalog.entry(for: .openPalm)
    #expect(fist.isReserved)
    #expect(palm.isReserved)
    // Loose fist is the clutch/activation gesture; open palm is the disarm gesture.
    #expect(fist.editorial.lowercased().contains("clutch"))
    #expect(palm.editorial.lowercased().contains("disarm"))
}

@Test func nonReservedEntriesAreNotReserved() {
    let nonReserved = GestureCatalog.entries.filter { !$0.isReserved }
    #expect(nonReserved.count == 19)
    for entry in nonReserved {
        #expect(entry.id != .looseFist && entry.id != .openPalm)
    }
}

@Test func everyCatalogEntryHasALegibleCannedFrame() {
    for entry in GestureCatalog.entries {
        #expect(
            entry.cannedFrame.joints.count >= 15,
            "\(entry.id) cannedFrame has only \(entry.cannedFrame.joints.count) joints, need >= 15"
        )
    }
}

@Test func victoryCannedFrameForksOutwardLikeARealV() {
    // A real "V" separates MORE at the fingertips than at the knuckles — the fork should widen
    // going out, never narrow back toward the center line (which would read as the fingers
    // closing back together instead of splaying apart).
    let frame = CannedFrames.victory
    func x(_ joint: HandJoint) -> Double { frame.point(joint)!.x }
    let mcpSeparation = abs(x(.middleMCP) - x(.indexMCP))
    let tipSeparation = abs(x(.middleTip) - x(.indexTip))
    #expect(mcpSeparation < 0.18, "MCP row separation \(mcpSeparation) should stay ~0.16")
    #expect(tipSeparation >= 0.18, "tip separation \(tipSeparation) should be >= 0.18")
    #expect(tipSeparation > mcpSeparation, "tips (\(tipSeparation)) should separate MORE than MCPs (\(mcpSeparation)), not converge")
}

@Test func cannedFrameMatchesItsOwnEntryID() {
    // `CatalogEntry.init` derives `cannedFrame` from `CannedFrames.frame(for: id)` — this just
    // guards that indirection against ever drifting (e.g. a future hand-edit that passes a
    // mismatched frame some other way).
    for entry in GestureCatalog.entries {
        #expect(entry.cannedFrame == CannedFrames.frame(for: entry.id))
    }
}
