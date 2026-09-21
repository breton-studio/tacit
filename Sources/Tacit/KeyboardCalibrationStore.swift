import Foundation
import TacitCore

@MainActor
final class KeyboardCalibrationStore: ObservableObject {
    @Published private(set) var profiles: [String: KeyboardHomeCalibrationProfile] = [:]
    @Published private(set) var lastError: String?

    private let fileURL: URL

    private struct Document: Codable {
        var profiles: [String: KeyboardHomeCalibrationProfile]
    }

    init(directory: URL = KeyboardCalibrationStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("keyboard-home-calibrations.json")
        load()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tacit", isDirectory: true)
    }

    func profile(for cameraID: String?) -> KeyboardHomeCalibrationProfile? {
        guard let cameraID, let profile = profiles[cameraID], profile.isCurrent else { return nil }
        return profile
    }

    @discardableResult
    func save(_ profile: KeyboardHomeCalibrationProfile) -> Bool {
        var updated = profiles
        updated[profile.cameraID] = profile

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(Document(profiles: updated))
            try data.write(to: fileURL, options: .atomic)
            profiles = updated
            lastError = nil
            return true
        } catch {
            lastError = "Could not save keyboard calibration."
            return false
        }
    }

    func removeProfile(for cameraID: String) {
        var updated = profiles
        updated.removeValue(forKey: cameraID)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(Document(profiles: updated))
            try data.write(to: fileURL, options: .atomic)
            profiles = updated
            lastError = nil
        } catch {
            lastError = "Could not remove keyboard calibration."
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return }
        profiles = document.profiles
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
