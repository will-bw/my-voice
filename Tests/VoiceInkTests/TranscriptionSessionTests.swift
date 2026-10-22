import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
private final class MockStreamingService: StreamingTranscriptionServicing {
    var startError: Error?
    var stopResult: Result<StreamingStopResult, Error> = .success(.finalized(text: "streaming"))
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var lastContext: TranscriptionRequestContext?

    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        startCount += 1
        lastContext = context
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
    private(set) var contexts: [TranscriptionRequestContext] = []

    init(_ result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        calls.append(model.name)
        contexts.append(context)
        return try result.get()
    }
}

private final class FailingStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let events = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { events.stream }
    var sendCount: Int { lock.withLock { calls } }

    func connect(model: any TranscriptionModel, language: String?) async throws {}
    func sendAudioChunk(_ data: Data) async throws {
        lock.withLock { calls += 1 }
        throw StreamingTranscriptionError.connectionFailed("connection lost")
    }
    func commit() async throws { XCTFail("Failed sender must not commit") }
    func disconnect() async { events.continuation.finish() }
}

private final class BufferedStreamingProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var audio = Data()
    private let events = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
    private let final = AsyncStream.makeStream(of: String.self)
    var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> { events.stream }
    var finalizationEvents: AsyncStream<String>? { final.stream }
    var sentAudio: Data { lock.withLock { audio } }
    func connect(model: any TranscriptionModel, language: String?) async throws {}
    func sendAudioChunk(_ data: Data) async throws { lock.withLock { audio.append(data) } }
    func commit() async throws { final.continuation.yield("完整文本"); final.continuation.finish() }
    func disconnect() async { events.continuation.finish(); final.continuation.finish() }
}

@MainActor
final class TranscriptionSessionTests: XCTestCase {
    func testStartupBudgetPreservesBacklogThenRestoresLiveLimit() async {
        let source = AudioChunkSource(maximumBufferedBytes: 128_000)
        XCTAssertTrue(source.send(Data(repeating: 1, count: 64_000)))
        XCTAssertTrue(source.send(Data(repeating: 2, count: 64_000)))
        XCTAssertFalse(source.send(Data([3])))
        source.finishStartupBuffering()
        let first = await source.next()
        XCTAssertEqual(first?.count, 64_000)
        // Existing data was preserved, and the normal two-second budget is restored.
        XCTAssertFalse(source.send(Data([3])))
        source.finish()
        let second = await source.next()
        XCTAssertEqual(second, Data(repeating: 2, count: 64_000))
        let end = await source.next()
        XCTAssertNil(end)
    }

    func testStartupAudioLongerThanTwoSecondsIsSentAndFinalizedWithoutFallback() async throws {
        let container = try ModelContainer(
            for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let provider = BufferedStreamingProvider()
        let service = StreamingTranscriptionService(modelContext: container.mainContext, providerFactory: { _ in provider })
        let audio = Data(repeating: 1, count: 96_000)
        // Mode preparation can release a multi-second burst before WebSocket connection.
        for offset in stride(from: 0, to: audio.count, by: 320) {
            service.sendAudioChunk(audio.subdata(in: offset..<min(offset + 320, audio.count)))
        }
        try await service.startStreaming(model: streamingModel, context: TranscriptionRequestContext(language: "auto", prompt: nil))
        let result = try await service.stopAndFinalize()
        guard case .finalized("完整文本") = result else { return XCTFail("Unexpected batch fallback") }
        XCTAssertEqual(provider.sentAudio, audio)
    }

    func testBackpressureStillSendsAcceptedAudioAndRequiresFullFileFallback() async throws {
        let container = try ModelContainer(
            for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let provider = BufferedStreamingProvider()
        let service = StreamingTranscriptionService(modelContext: container.mainContext, providerFactory: { _ in provider })
        let audio = Data(repeating: 1, count: 640_000)
        service.sendAudioChunk(audio)
        service.sendAudioChunk(Data([2])) // Startup budget is bounded; this chunk is dropped.
        try await service.startStreaming(model: streamingModel, context: TranscriptionRequestContext(language: "auto", prompt: nil))
        do {
            _ = try await service.stopAndFinalize()
            XCTFail("Incomplete audio must use full-file fallback")
        } catch let error as StreamingTranscriptionError {
            guard case .audioBackpressureExceeded = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(provider.sentAudio, audio, "Backpressure must not stop a healthy sender")
    }

    func testProviderFailureAfterBackpressureStillStopsSending() async throws {
        let container = try ModelContainer(
            for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let provider = FailingStreamingProvider()
        let service = StreamingTranscriptionService(modelContext: container.mainContext, providerFactory: { _ in provider })
        for _ in 0..<3 { service.sendAudioChunk(Data(repeating: 1, count: 320_000)) }
        try await service.startStreaming(model: streamingModel, context: TranscriptionRequestContext(language: "auto", prompt: nil))
        do { _ = try await service.stopAndFinalize(); XCTFail("Expected fallback") } catch {}
        XCTAssertEqual(provider.sendCount, 1)
    }

    func testAudioChunkSourceEnforcesByteBudgetAndDrainsBeforeFinish() async {
        XCTAssertEqual(AudioChunkSource.defaultMaximumBufferedBytes, 64_000)
        let source = AudioChunkSource(maximumBufferedBytes: 4)
        let first = Data([1, 2])
        let second = Data([3, 4])

        XCTAssertTrue(source.send(first))
        XCTAssertTrue(source.send(second))
        XCTAssertFalse(source.send(Data([5])))
        let drainedFirst = await source.next()
        XCTAssertEqual(drainedFirst, first)
        XCTAssertTrue(source.send(Data([5])))

        source.finish()
        let drainedSecond = await source.next()
        let drainedThird = await source.next()
        let finished = await source.next()
        XCTAssertEqual(drainedSecond, second)
        XCTAssertEqual(drainedThird, Data([5]))
        XCTAssertNil(finished)
        XCTAssertFalse(source.send(Data([6])))
    }

    func testStreamingSenderStopsAfterFirstFailureAndRejectsQueuedChunks() async throws {
        let container = try ModelContainer(
            for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let provider = FailingStreamingProvider()
        let service = StreamingTranscriptionService(
            modelContext: container.mainContext, providerFactory: { _ in provider }
        )
        // Queue before connecting so the failure always has pending chunks behind it.
        for _ in 0..<5 { service.sendAudioChunk(Data([1, 2])) }
        try await service.startStreaming(
            model: streamingModel, context: TranscriptionRequestContext(language: "auto", prompt: nil)
        )
        do {
            _ = try await service.stopAndFinalize()
            XCTFail("Expected original send failure")
        } catch let error as StreamingTranscriptionError {
            guard case .connectionFailed("connection lost") = error else {
                XCTFail("Expected original connection error, got \(error)")
                return
            }
        }
        XCTAssertEqual(provider.sendCount, 1)
        service.sendAudioChunk(Data([3, 4]))
        XCTAssertEqual(provider.sendCount, 1)
    }

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

    func testStreamingAndBatchFallbackShareRecognitionHintSnapshot() async throws {
        let streaming = MockStreamingService()
        streaming.stopResult = .failure(StreamingTranscriptionError.connectionFailed("offline"))
        let batch = MockTranscriptionService(.success("batch"))
        let local = MockTranscriptionService(.success("local"))
        let session = makeSession(streaming: streaming, batch: batch, local: local)
        let snapshot = RecognitionHintSnapshot(
            vocabulary: ["Morrow": 5],
            languageHints: ["zh"],
            context: "Morrow",
            experimentArm: .dynamic,
            candidateCount: 1,
            contextKind: "selected-text",
            sourceTypes: ["selected-text"],
            privacyDecision: "allowed",
            selectionTrace: RecognitionHintSelectionTrace(candidateCount: 1, selectedCount: 1, suppressedCount: 0)
        )
        _ = try await session.prepare(configuration: configuration(recognitionHints: snapshot))

        _ = try await session.transcribe(audioURL: try temporaryAudioFile())

        XCTAssertEqual(streaming.lastContext?.recognitionHints, snapshot)
        XCTAssertEqual(batch.contexts.first?.recognitionHints, snapshot)
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

    private func configuration(recognitionHints: RecognitionHintSnapshot? = nil) -> TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Test", isAIEnhancementEnabled: false),
            model: streamingModel,
            language: "zh",
            isRealtimeEnabled: true,
            recognitionHints: recognitionHints
        )
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0, 1, 2]).write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
