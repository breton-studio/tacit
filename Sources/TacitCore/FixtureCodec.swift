import Foundation

public enum FixtureCodec {
    public static func encode(_ frames: [LandmarkFrame]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(frames)
    }

    public static func decode(_ data: Data) throws -> [LandmarkFrame] {
        let decoder = JSONDecoder()
        return try decoder.decode([LandmarkFrame].self, from: data)
    }
}
