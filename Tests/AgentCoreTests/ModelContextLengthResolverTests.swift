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

    func testPrefersMaxOfNativeAndMaxOverLoaded32k() {
        let item: [String: Any] = [
            "id": "unsloth/Nemotron-3-Nano-30B-A3B-GGUF",
            "context_length": 32_768,
            "max_context_length": 1_048_576,
            "native_context_length": 1_048_576,
        ]
        XCTAssertEqual(ModelContextLengthResolver.fromAPIItem(item), 1_048_576)
        XCTAssertEqual(
            ModelContextLengthResolver.advertisedMax(
                nativeContextLength: 1_048_576,
                maxContextLength: 1_048_576,
                contextLength: 32_768),
            1_048_576)
    }

    func testOmittingAllThreeDoesNotInventOneMillion() {
        let item: [String: Any] = [
            "id": "unsloth/Nemotron-3-Nano-30B-A3B-GGUF",
            "loaded": true,
        ]
        XCTAssertNil(ModelContextLengthResolver.fromAPIItem(item))
        XCTAssertNil(
            ModelContextLengthResolver.resolve(
                modelId: "unsloth/Nemotron-3-Nano-30B-A3B-GGUF",
                apiValue: nil))
        XCTAssertNil(ModelContextLengthResolver.advertisedMax())
    }

    func testSettingsDefault32768DoesNotBeatAdvertised() {
        let advertised = ModelContextLengthResolver.fromAPIItem([
            "context_length": 32_768,
            "native_context_length": 1_048_576,
        ])
        XCTAssertEqual(
            ContextBudget.effectiveContextLength(
                stored: ModelSettings.defaultContextLength,
                advertised: advertised),
            1_048_576)
    }

    func testSettingsDefaultUsedOnlyWhenNothingAdvertised() {
        XCTAssertEqual(
            ContextBudget.effectiveContextLength(
                stored: ModelSettings.defaultContextLength,
                advertised: nil),
            32_768)
    }
}
