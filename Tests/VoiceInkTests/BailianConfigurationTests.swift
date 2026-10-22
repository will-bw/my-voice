import XCTest
@testable import VoiceInk

private final class BailianTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

final class BailianConfigurationTests: XCTestCase {
    func testOnboardingRequiresSenseVoiceAndCompleteBailianConfiguration() {
        XCTAssertEqual(OnboardingTranscriptionPolicy.localFallbackModelName, "sensevoice-small")
        XCTAssertEqual(OnboardingTranscriptionPolicy.defaultSetupKind, .cloud)
        XCTAssertEqual(OnboardingTranscriptionPolicy.recommendedCloudProviderKey, "Bailian")
        XCTAssertFalse(
            OnboardingTranscriptionPolicy.isProviderReady(
                providerKey: "Bailian", hasAPIKey: true, hasValidBailianConfiguration: false))
        XCTAssertTrue(
            OnboardingTranscriptionPolicy.isProviderReady(
                providerKey: "Bailian", hasAPIKey: true, hasValidBailianConfiguration: true))
        XCTAssertFalse(
            OnboardingTranscriptionPolicy.isProviderReady(
                providerKey: "Bailian", hasAPIKey: false, hasValidBailianConfiguration: true))
        XCTAssertTrue(
            OnboardingTranscriptionPolicy.isProviderReady(
                providerKey: "Deepgram", hasAPIKey: true, hasValidBailianConfiguration: false))
    }

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
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.protocolViolation("out of order")), .transientFailure)
        XCTAssertEqual(BailianProviderHealth.classify(BailianError.invalidResponse("malformed")), .transientFailure)
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
            .requestRejected(statusCode: 400)
        )
        XCTAssertEqual(
            BailianErrorMapper.mapTaskFailure(code: "SERVER_ERROR", message: "internal failure"),
            .server(statusCode: 500)
        )
    }

    func testResponseAndSessionFailuresDoNotSuppressNextAttempt() async throws {
        let store = BailianProviderHealthStore()
        for error in [BailianError.protocolViolation("out of order"), .invalidResponse("missing output"), .emptyFinal] {
            await store.record(error)
            try await store.ensureAttemptAllowed()
        }
        await store.record(BailianError.misconfigured("bad endpoint"))
        do {
            try await store.ensureAttemptAllowed()
            XCTFail("A known configuration failure should still be suppressed")
        } catch let error as BailianError {
            XCTAssertEqual(error, .misconfigured("请检查百炼配置，稍后将自动重试"))
        }
    }

    func testNoWordsMappingDoesNotMaskOtherHTTPErrorsOrExposeBody() {
        let body = Data(#"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS secret detail"}"#.utf8)
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 400, responseBody: body), .emptyFinal)
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 401, responseBody: body), .invalidCredential(statusCode: 401))
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 403, responseBody: body), .invalidCredential(statusCode: 403))
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 429, responseBody: body), .rateLimited)
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 503, responseBody: body), .server(statusCode: 503))
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 400, responseBody: Data("not JSON".utf8)), .requestRejected(statusCode: 400))
        XCTAssertEqual(BailianErrorMapper.map(statusCode: 400, responseBody: Data(#"{"code":"CLIENT_ERROR","message":"bad model secret detail"}"#.utf8)), .requestRejected(statusCode: 400))
        XCTAssertEqual(BailianErrorMapper.mapTaskFailure(code: "CLIENT_ERROR", message: "ASR_RESPONSE_HAVE_NO_WORDS secret detail"), .emptyFinal)
        XCTAssertEqual(BailianErrorMapper.mapTaskFailure(code: "ASR_RESPONSE_HAVE_NO_WORDS", message: nil), .emptyFinal)
    }

    func testWebSocketUpgradePreservesUnderlyingFailure() {
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 101, underlyingError: lost), BailianErrorMapper.map(lost))
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 101, underlyingError: URLError(.timedOut)), .timeout)
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 101, underlyingError: CancellationError()), .canceled)
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: nil, underlyingError: lost), BailianErrorMapper.map(lost))
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 401, underlyingError: lost), .invalidCredential(statusCode: 401))
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 403, underlyingError: lost), .invalidCredential(statusCode: 403))
        XCTAssertEqual(BailianErrorMapper.mapWebSocketFailure(statusCode: 429, underlyingError: lost), .rateLimited)
    }

    func testBlockedHealthAutomaticallyAllowsRetryAfterCooldown() async throws {
        for error in [BailianError.invalidCredential(statusCode: 403), .misconfigured("bad endpoint")] {
            let clock = BailianTestClock()
            let store = BailianProviderHealthStore(now: { clock.now() })
            await store.record(error)
            clock.advance(by: .seconds(29))
            do {
                try await store.ensureAttemptAllowed()
                XCTFail("Expected suppression during cooldown")
            } catch is BailianError {}
            clock.advance(by: .seconds(1))
            try await store.ensureAttemptAllowed()
            let health = await store.health
            XCTAssertEqual(health, .unknown)
        }
    }

    func testSuppressedAttemptsDoNotExtendRecoveryDeadline() async throws {
        for original in [BailianError.invalidCredential(statusCode: 401), .misconfigured("bad endpoint")] {
            let clock = BailianTestClock()
            let store = BailianProviderHealthStore(now: { clock.now() })
            await store.record(original)
            for _ in 0..<29 {
                clock.advance(by: .seconds(1))
                do {
                    try await store.ensureAttemptAllowed()
                    XCTFail("Expected cooldown")
                } catch {
                    // Streaming can report the local guard error through its connection catch.
                    await store.record(error)
                }
            }
            clock.advance(by: .seconds(1))
            try await store.ensureAttemptAllowed()
        }
    }
}
