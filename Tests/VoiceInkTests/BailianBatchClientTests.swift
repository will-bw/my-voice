import Foundation
import XCTest
@testable import VoiceInk

private actor MockHTTPTransport: BailianHTTPTransport {
    let data: Data
    let statusCode: Int
    private(set) var request: URLRequest?

    init(statusCode: Int, json: String) {
        self.statusCode = statusCode
        data = Data(json.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
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
        let client = BailianBatchClient(configuration: try configuration(), transport: transport)
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
            (401, .invalidCredential(statusCode: 401)),
            (403, .invalidCredential(statusCode: 403)),
            (429, .rateLimited),
            (503, .server(statusCode: 503)),
        ]
        for (status, expected) in cases {
            let transport = MockHTTPTransport(statusCode: status, json: "{}")
            let client = BailianBatchClient(configuration: try configuration(), transport: transport)
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
        let client = BailianBatchClient(configuration: try configuration(), transport: transport)
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
}
