import Foundation
import XCTest
@testable import VoiceInk

private actor MockHTTPTransport: BailianHTTPTransport {
    private var responses: [(Int, Data)]
    private(set) var requestCount = 0
    private(set) var request: URLRequest?

    init(statusCode: Int, json: String) {
        responses = [(statusCode, Data(json.utf8))]
    }

    init(responses: [(Int, String)]) {
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        requestCount += 1
        let (statusCode, data) = responses.count > 1 ? responses.removeFirst() : responses[0]
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

final class BailianBatchClientTests: XCTestCase {
    private func configuration() throws -> BailianConfiguration {
        try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
    }

    func testBuildsOfficialSynchronousRequestAndParsesFinal() async throws {
        let transport = MockHTTPTransport(
            statusCode: 200,
            json: #"{"output":{"output":{"sentence":{"text":"识别结果"}},"text":"识别结果"},"request_id":"req-1"}"#
        )
        let client = BailianBatchClient(
            configuration: try configuration(),
            transport: transport,
            healthStore: BailianProviderHealthStore()
        )
        let hints = try BailianRecognitionHints(
            vocabulary: ["百炼": 4],
            languageHints: ["zh", "en"],
            context: "专业语音输入"
        )
        let result = try await client.transcribe(
            audioData: Data([0, 1, 2]),
            fileName: "test.wav",
            apiKey: "secret-key",
            hints: hints,
            timeout: 5
        )

        XCTAssertEqual(result, BailianBatchResult(text: "识别结果", requestID: "req-1"))
        let capturedRequest = await transport.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, BailianConfiguration.batchModel)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("secret-key"))
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        let firstContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(firstContent[0]["type"] as? String, "input_text")
        let secondContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(secondContent[0]["type"] as? String, "input_audio")
    }

    func testHTTPErrorMatrix() async throws {
        let cases: [(Int, BailianError)] = [
            (400, .requestRejected(statusCode: 400)),
            (404, .requestRejected(statusCode: 404)),
            (422, .requestRejected(statusCode: 422)),
            (401, .invalidCredential(statusCode: 401)),
            (403, .invalidCredential(statusCode: 403)),
            (429, .rateLimited),
            (503, .server(statusCode: 503)),
        ]
        for (status, expected) in cases {
            let transport = MockHTTPTransport(statusCode: status, json: "{}")
            let client = BailianBatchClient(
                configuration: try configuration(),
                transport: transport,
                healthStore: BailianProviderHealthStore()
            )
            do {
                _ = try await client.transcribe(
                    audioData: Data([0]),
                    fileName: "test.wav",
                    apiKey: "secret",
                    hints: try BailianRecognitionHints(),
                    timeout: 1
                )
                XCTFail("Expected HTTP \(status) to fail")
            } catch let error as BailianError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testEmptyFinalIsRejected() async throws {
        let transport = MockHTTPTransport(statusCode: 200, json: #"{"output":{"text":"   "}}"#)
        let client = BailianBatchClient(
            configuration: try configuration(),
            transport: transport,
            healthStore: BailianProviderHealthStore()
        )
        do {
            _ = try await client.transcribe(
                audioData: Data([0]),
                fileName: "test.wav",
                apiKey: "secret",
                hints: try BailianRecognitionHints(),
                timeout: 1
            )
            XCTFail("Expected empty final")
        } catch let error as BailianError {
            XCTAssertEqual(error, .emptyFinal)
        }
    }

    func testNoWords400AllowsNextRequestWithoutReset() async throws {
        let noWordsBodies = [
            #"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS","request_id":"silent"}"#,
            #"{"code":"ASR_RESPONSE_HAVE_NO_WORDS","message":"No words"}"#,
        ]
        for body in noWordsBodies {
            let healthStore = BailianProviderHealthStore()
            let transport = MockHTTPTransport(responses: [
                (400, body),
                (200, #"{"output":{"text":"下一次正常识别"}}"#),
            ])
            let client = BailianBatchClient(
                configuration: try configuration(), transport: transport, healthStore: healthStore
            )
            do {
                _ = try await client.transcribe(
                    audioData: Data([0]), fileName: "silent.wav", apiKey: "secret",
                    hints: BailianRecognitionHints(), timeout: 1
                )
                XCTFail("Expected no words to fail this recording only")
            } catch let error as BailianError {
                XCTAssertEqual(error, .emptyFinal)
            }
            try await healthStore.ensureAttemptAllowed()
            let result = try await client.transcribe(
                audioData: Data([1]), fileName: "speech.wav", apiKey: "secret",
                hints: BailianRecognitionHints(), timeout: 1
            )
            XCTAssertEqual(result.text, "下一次正常识别")
            let requestCount = await transport.requestCount
            XCTAssertEqual(requestCount, 2)
        }
    }

    func testUnknown400BodiesAllowNextBatchRequestWithoutReset() async throws {
        // {} was captured from a real silent-audio request on 2026-10-06.
        for body in ["{}", "", "<html>Bad Request</html>", #"{"output":{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS"}}"#] {
            let store = BailianProviderHealthStore()
            let transport = MockHTTPTransport(responses: [
                (400, body), (200, #"{"output":{"text":"恢复成功"}}"#),
            ])
            let client = BailianBatchClient(configuration: try configuration(), transport: transport, healthStore: store)
            do {
                _ = try await client.transcribe(
                    audioData: Data([0]), fileName: "silent.wav", apiKey: "secret",
                    hints: BailianRecognitionHints(), timeout: 1
                )
                XCTFail("Expected rejection of this recording")
            } catch let error as BailianError {
                XCTAssertEqual(error, .requestRejected(statusCode: 400))
            }
            let result = try await client.transcribe(
                audioData: Data([1]), fileName: "speech.wav", apiKey: "secret",
                hints: BailianRecognitionHints(), timeout: 1
            )
            XCTAssertEqual(result.text, "恢复成功")
            let count = await transport.requestCount
            XCTAssertEqual(count, 2)
        }
    }
}
