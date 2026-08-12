import XCTest
@testable import AgentCore

final class OMLXModelManagerBusyTests: XCTestCase {

    /// Ensures incomplete-shard preflight (shipped path) still fires for
    /// missing weight maps — pure function on the real type.
    func testIncompleteShardMessageNilWithoutIndex() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("omlx-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let msg = OMLXModelManager.incompleteShardMessage(
            modelID: "x", modelPath: tmp.path)
        XCTAssertNil(msg)
    }

    func testHumanizeLoadFailurePreviousFailure() {
        let raw = #"{"error":{"message":"unavailable after previous load failure"}}"#
        let msg = OMLXModelManager.humanizeLoadFailure(modelID: "GLM", raw: raw)
        XCTAssertTrue(msg.contains("previous failure") || msg.contains("refuses"), msg)
    }
}
