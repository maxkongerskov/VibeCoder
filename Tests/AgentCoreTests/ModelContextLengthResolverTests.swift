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

    func testLoadedWindowKeeps32kWhenNativeIs1M() {
        XCTAssertEqual(
            ModelContextLengthResolver.loadedWindow(
                nativeContextLength: 1_048_576,
                maxContextLength: 1_048_576,
                contextLength: 32_768),
            32_768)
    }

    func testHonestyLabelShowsBothWhenNative1MAndLoaded32k() {
        for native in [1_048_576, 1_000_000] {
            let label = ModelContextLengthResolver.honestyLabel(
                nativeMax: native, loaded: 32_768)
            XCTAssertTrue(label.localizedCaseInsensitiveContains("loaded"), label)
            XCTAssertTrue(label.localizedCaseInsensitiveContains("native"), label)
            XCTAssertTrue(
                label.contains("1.0M") || label.contains("1M"),
                "must surface 1M native, got \(label)")
            XCTAssertTrue(
                label.contains("32.8k") || label.contains("32k"),
                "must surface loaded 32k, got \(label)")
            XCTAssertNotEqual(label, ContextUsageBreakdown.formatTokenCount(32_768))
            XCTAssertNotEqual(label, "32k")
            XCTAssertNotEqual(label, "32.8k")
        }
        let fromItem = ModelContextLengthResolver.honestyLabel(fromAPIItem: [
            "native_context_length": 1_048_576,
            "max_context_length": 1_048_576,
            "context_length": 32_768,
        ])
        XCTAssertTrue(fromItem.contains("1.0M") || fromItem.contains("1M"), fromItem)
        XCTAssertTrue(fromItem.contains("32.8k") || fromItem.contains("32k"), fromItem)
        XCTAssertTrue(fromItem.localizedCaseInsensitiveContains("loaded"))
        XCTAssertTrue(fromItem.localizedCaseInsensitiveContains("native"))
        XCTAssertNotEqual(fromItem, ContextUsageBreakdown.formatTokenCount(32_768))
    }

    func testHonestyLabelSingleNumberWhenWindowsMatch() {
        let same = ModelContextLengthResolver.honestyLabel(
            nativeMax: 32_768, loaded: 32_768)
        XCTAssertEqual(same, ContextUsageBreakdown.formatTokenCount(32_768))
        XCTAssertFalse(same.localizedCaseInsensitiveContains("native"))
    }

}
