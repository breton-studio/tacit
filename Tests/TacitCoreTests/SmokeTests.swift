import Testing
@testable import TacitCore

@Test func coreVersionExists() {
    #expect(TacitCoreInfo.version == "0.1.0")
}
