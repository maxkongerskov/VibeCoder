import XCTest
@testable import AgentCore

final class ModelContextLengthResolverTests: XCTestCase {

    func testFromAPIItemReadsSnakeCaseFields() {
        let item: [String: Any] = ["id": "m1", "context_length": 131072]
        XCTAssertEqual(ModelContextLengthResolver.fromAPIItem(item), 131_072)
    }

    func testResolveUsesAPIValueFirst() {
        XCTAssertEqual(
            ModelContextLengthResolver.resolve(modelId: "custom", apiValue: 200_000),
            200_000)
    }

    func testResolveKnownGLMModelWithoutAPIValue() {
        XCTAssertEqual(
            ModelContextLengthResolver.resolve(modelId: "GLM-5.2-mxfp4", apiValue: nil),
            256_000)
    }
}