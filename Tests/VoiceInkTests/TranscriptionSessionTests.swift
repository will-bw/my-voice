import Foundation
import XCTest
@testable import VoiceInk

@MainActor
private final class MockStreamingService: StreamingTranscriptionServicing {
    var startError: Error?
    var stopResult: Result<StreamingStopResult, Error> = .success(.finalized(text: "streaming"))
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        startCount += 1
        if let startError { throw startError }
    }

    nonisolated func sendAudioChunk(_ data: Data) {}

    func stopAndFinalize() async throws -> StreamingStopResult {
        stopCount += 1
        return try stopResult.get()
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class MockTranscriptionService: TranscriptionService {
    var result: Result<String, Error>
    private(set) var calls: [String] = []

    init(_ result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        calls.append(model.name)
        return try result.get()
    }
}

@MainActor
final class TranscriptionSessionTests: XCTestCase {
    private let streamingModel = CloudModel(
        name: "streaming-model",
        displayName: "Streaming Model",
        description: "test",
        provider: .bailian,
        isMultilingual: true,
        supportsStreaming: true,
        supportedLanguages: ["zh": "Chinese"]
    )
    private let batchModel = CloudModel(
        name: "batch-model",
        displayName: "Batch Model",
        description: "test",
        provider: .bailian,
        isMultilingual: true,
        supportedLanguages: ["zh": "Chinese"]
    )
    private let localModel = TranscribeCppModel(
        name: "sensevoice-small",
        displayName: "SenseVoice Small",
        description: "test",
        size: "1 MB",
        speed: 1,
        accuracy: 1,
        ramUsage: 1,
        publisher: "test",
        supportedLanguages: ["zh": "Chinese"]
    )

    func testCommittedTranscriptMergeHandlesCumulativeAndSegmentEvents() {
        var segments = StreamingTranscriptMerge.merge(existing: [], incoming: "第一句")
        segments = StreamingTranscriptMerge.merge(existing: segments, incoming: "第一句第二句")
        XCTAssertEqual(segments, ["第一句第二句"])

        segments = StreamingTranscriptMerge.merge(existing: segments, incoming: "第三句")
        XCTAssertEqual(segments, ["第一句第二句", "第三句"])
    }

    func testStreamingSuccessDoesNotInvokeFallbacks() async throws {
        let streaming = MockStreamingService()
        let batch = MockTranscriptionService(.success("batch"))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        _ = try await session.prepare(configuration: configuration())

        let result = try await session.transcribe(audioURL: try temporaryAudioFile())

        XCTAssertEqual(result.text, "streaming")
        XCTAssertEqual(result.route, .streaming)
        XCTAssertEqual(result.modelDisplayName, "Streaming Model")
        XCTAssertTrue(batch.calls.isEmpty)
        XCTAssertTrue(local.calls.isEmpty)
    }

    func testStreamingFailureUsesBatchFallback() async throws {
        let streaming = MockStreamingService()
        streaming.stopResult = .failure(StreamingTranscriptionError.connectionFailed("offline"))
        let batch = MockTranscriptionService(.success("batch"))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        _ = try await session.prepare(configuration: configuration())

        let result = try await session.transcribe(audioURL: try temporaryAudioFile())

        XCTAssertEqual(result.text, "batch")
        XCTAssertEqual(result.route, .batchFallback)
        XCTAssertEqual(result.modelDisplayName, "Batch Model")
        XCTAssertEqual(batch.calls, ["batch-model"])
        XCTAssertTrue(local.calls.isEmpty)
    }

    func testBatchFailureUsesInstalledLocalFallback() async throws {
        let streaming = MockStreamingService()
        streaming.stopResult = .failure(StreamingTranscriptionError.rateLimited)
        let batch = MockTranscriptionService(.failure(CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "rate")))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        _ = try await session.prepare(configuration: configuration())

        let result = try await session.transcribe(audioURL: try temporaryAudioFile())

        XCTAssertEqual(result.text, "local")
        XCTAssertEqual(result.route, .localFallback)
        XCTAssertEqual(result.modelDisplayName, "SenseVoice Small")
        XCTAssertEqual(local.calls, ["sensevoice-small"])
    }

    func testNoSpeechDoesNotTriggerFallback() async throws {
        let streaming = MockStreamingService()
        streaming.stopResult = .failure(StreamingTranscriptionError.noSpeech)
        let batch = MockTranscriptionService(.success("batch"))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        _ = try await session.prepare(configuration: configuration())

        do {
            _ = try await session.transcribe(audioURL: try temporaryAudioFile())
            XCTFail("Expected no-speech failure")
        } catch let error as StreamingTranscriptionError {
            guard case .noSpeech = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(batch.calls.isEmpty)
        XCTAssertTrue(local.calls.isEmpty)
    }

    func testCancellationDoesNotTriggerFallback() async throws {
        let streaming = MockStreamingService()
        let batch = MockTranscriptionService(.success("batch"))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        _ = try await session.prepare(configuration: configuration())
        session.cancel()

        do {
            _ = try await session.transcribe(audioURL: try temporaryAudioFile())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(batch.calls.isEmpty)
        XCTAssertTrue(local.calls.isEmpty)
    }

    private func makeSession(
        streaming: MockStreamingService,
        batch: MockTranscriptionService,
        local: MockTranscriptionService
    ) -> StreamingTranscriptionSession {
        StreamingTranscriptionSession(
            streamingService: streaming,
            batchFallbackService: batch,
            batchFallbackModel: batchModel,
            localFallback: LocalTranscriptionFallback(service: local, model: localModel)
        )
    }

    private func configuration() -> TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Test", isAIEnhancementEnabled: false),
            model: streamingModel,
            language: "zh",
            isRealtimeEnabled: true
        )
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0, 1, 2]).write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
