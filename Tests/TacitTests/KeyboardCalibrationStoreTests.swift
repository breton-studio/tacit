import Foundation
import Testing
@testable import Tacit
import TacitCore

@MainActor
@Test func keyboardCalibrationStoreRoundTripsPerCamera() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = KeyboardCalibrationStore(directory: directory)
    let profile = testProfile(cameraID: "brio")
    #expect(store.save(profile))
    #expect(store.profile(for: "brio") == profile)
    #expect(store.profile(for: "other") == nil)

    let reloaded = KeyboardCalibrationStore(directory: directory)
    #expect(reloaded.profile(for: "brio") == profile)
}

@MainActor
@Test func keyboardCalibrationStoreRejectsStaleSchema() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = KeyboardCalibrationStore(directory: directory)
    var stale = testProfile(cameraID: "brio")
    stale.schemaVersion = 0
    #expect(store.save(stale))
    #expect(store.profile(for: "brio") == nil)
}

private func testProfile(cameraID: String) -> KeyboardHomeCalibrationProfile {
    KeyboardHomeCalibrationProfile(
        cameraID: cameraID,
        cameraName: "Brio 500",
        cameraDeviceType: "external",
        imageSplitX: 0.5,
        leftRule: KeyboardLiftRule(
            side: .left,
            direction: .lower,
            enterCenterY: 0.4,
            exitCenterY: 0.45,
            typingMedianCenterY: 0.6,
            liftedMedianCenterY: 0.2,
            separationAUC: 1
        ),
        rightRule: KeyboardLiftRule(
            side: .right,
            direction: .lower,
            enterCenterY: 0.4,
            exitCenterY: 0.45,
            typingMedianCenterY: 0.6,
            liftedMedianCenterY: 0.2,
            separationAUC: 1
        ),
        createdAt: Date(timeIntervalSince1970: 1)
    )
}
