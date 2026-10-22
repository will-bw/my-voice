import XCTest

@testable import VoiceInk

final class CustomProviderReasoningTests: XCTestCase {
    func testBailianQwenDisablesThinking() throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")
        )

        let extraBody = ReasoningConfig.customExtraBodyParameters(
            baseURL: baseURL,
            modelName: "qwen3.8-flash"
        )

        XCTAssertEqual(extraBody?["enable_thinking"] as? Bool, false)
    }

    func testNonBailianCustomProviderIsUnchanged() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/v1/chat/completions"))

        XCTAssertNil(
            ReasoningConfig.customExtraBodyParameters(
                baseURL: baseURL,
                modelName: "qwen3.8-flash"
            )
        )
    }

    func testNonQwenBailianModelIsUnchanged() throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")
        )

        XCTAssertNil(
            ReasoningConfig.customExtraBodyParameters(
                baseURL: baseURL,
                modelName: "other-model"
            )
        )
    }
}
