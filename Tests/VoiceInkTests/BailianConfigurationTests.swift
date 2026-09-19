import XCTest
@testable import VoiceInk

final class BailianConfigurationTests: XCTestCase {
    func testWorkspaceEndpointsAreRegionBound() throws {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "ws-123")
        XCTAssertEqual(
            configuration.httpEndpoint.absoluteString,
            "https://ws-123.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        )
        XCTAssertEqual(
            configuration.webSocketEndpoint.absoluteString,
            "wss://ws-123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        )
    }

    func testRejectsInvalidWorkspaceAndInsecureEndpoints() {
        XCTAssertThrowsError(try BailianConfiguration(region: .chinaNorth2, workspaceID: ""))
        XCTAssertThrowsError(try BailianConfiguration(region: .chinaNorth2, workspaceID: "-workspace"))
        XCTAssertThrowsError(try BailianConfiguration(region: .chinaNorth2, workspaceID: "工作空间"))
        XCTAssertThrowsError(
            try BailianConfiguration(
                region: .singapore,
                workspaceID: "workspace",
                customHTTPEndpoint: URL(string: "http://example.com")
            )
        )
        XCTAssertThrowsError(
            try BailianConfiguration(
                region: .singapore,
                workspaceID: "workspace",
                customWebSocketEndpoint: URL(string: "ws://example.com")
            )
        )
        XCTAssertThrowsError(
            try BailianConfiguration(
                region: .singapore,
                workspaceID: "workspace",
                customHTTPEndpoint: URL(string: "https:missing-host")
            )
        )
    }

    func testHintLimitsMatchOfficialProtocol() throws {
        XCTAssertThrowsError(try BailianRecognitionHints(vocabulary: ["term": 6]))
        XCTAssertThrowsError(try BailianRecognitionHints(languageHints: ["zh", "en", "ja", "ko", "fr"]))
        XCTAssertThrowsError(try BailianRecognitionHints(context: String(repeating: "字", count: 401)))

        let valid = try BailianRecognitionHints(
            vocabulary: ["my-voice": 4, "百炼": 50],
            languageHints: ["zh", "en"],
            context: "语音输入项目"
        )
        XCTAssertEqual(valid.vocabulary["百炼"], 50)
    }

    func testErrorClassificationMatrix() {
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.invalidCredential(statusCode: 401)), .invalidCredential)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.rateLimited), .transientFailure)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.server(statusCode: 503)), .transientFailure)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.timeout), .transientFailure)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.misconfigured("bad endpoint")), .misconfigured)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.emptyFinal), .healthy)
    }

    func testProviderHealthSuppressesKnownBadConfigurationUntilReset() async throws {
        let store = BailianProviderHealthStore()
        await store.record(BailianError.invalidCredential(statusCode: 401))

        do {
            try await store.ensureAttemptAllowed()
            XCTFail("Expected known invalid credential to be suppressed")
        } catch let error as BailianError {
            XCTAssertEqual(error, .invalidCredential(statusCode: 401))
        }

        await store.reset()
        try await store.ensureAttemptAllowed()
    }

    func testTaskFailureMappingDoesNotExposeServerMessage() {
        XCTAssertEqual(
            BailianErrorMapper.mapTaskFailure(code: "CLIENT_ERROR", message: "Invalid API key"),
            .invalidCredential(statusCode: 401)
        )
        XCTAssertEqual(
            BailianErrorMapper.mapTaskFailure(code: "CLIENT_ERROR", message: "request timeout after 23 seconds"),
            .timeout
        )
        XCTAssertEqual(
            BailianErrorMapper.mapTaskFailure(code: "CLIENT_ERROR", message: "bad request"),
            .misconfigured("服务端拒绝了请求参数")
        )
        XCTAssertEqual(
            BailianErrorMapper.mapTaskFailure(code: "SERVER_ERROR", message: "internal failure"),
            .server(statusCode: 500)
        )
    }
}
