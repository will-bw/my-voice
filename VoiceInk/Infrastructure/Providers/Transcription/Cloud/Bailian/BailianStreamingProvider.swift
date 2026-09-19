import Foundation
import SwiftData

final class BailianStreamingProvider: StreamingTranscriptionProvider {
    private let modelContext: ModelContext
    private var session: BailianStreamingSession?
    private var forwardingTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var finalContinuation: AsyncStream<String>.Continuation?
    private var startedContinuation: AsyncStream<Void>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    private let fullFinalizationEvents: AsyncStream<String>
    var finalizationEvents: AsyncStream<String>? { fullFinalizationEvents }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        var eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { eventContinuation = $0 }
        self.eventContinuation = eventContinuation

        var finalContinuation: AsyncStream<String>.Continuation!
        fullFinalizationEvents = AsyncStream { finalContinuation = $0 }
        self.finalContinuation = finalContinuation
    }

    deinit {
        forwardingTask?.cancel()
        eventContinuation?.finish()
        finalContinuation?.finish()
        startedContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "Bailian"), !apiKey.isEmpty else {
            throw StreamingTranscriptionError.missingAPIKey
        }
        let configuration: BailianConfiguration
        do {
            configuration = try BailianConfigurationStore.shared.load()
        } catch {
            throw map(error)
        }

        let vocabulary = try dictionaryHints()
        let hints = try BailianRecognitionHints(
            vocabulary: vocabulary,
            languageHints: (language == nil || language == "auto") ? [] : [language!]
        )
        let session = BailianStreamingSession(
            configuration: configuration,
            transport: BailianURLSessionWebSocketTransport()
        )
        self.session = session

        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        self.startedContinuation = startedContinuation
        forwardingTask = Task { [weak self] in
            for await output in session.outputs {
                guard let self else { return }
                switch output {
                case .sessionStarted:
                    self.eventContinuation?.yield(.sessionStarted)
                    self.startedContinuation?.yield(())
                    self.startedContinuation?.finish()
                case .partial(let text):
                    self.eventContinuation?.yield(.partial(text: text))
                case .committed(let text):
                    self.eventContinuation?.yield(.committed(text: text))
                case .final(let text):
                    self.finalContinuation?.yield(text)
                    self.finalContinuation?.finish()
                case .failed(let error):
                    self.eventContinuation?.yield(.error(self.map(error)))
                    self.finalContinuation?.finish()
                    self.startedContinuation?.finish()
                }
            }
        }

        do {
            try await session.connect(apiKey: apiKey, hints: hints)
            try await waitForStarted(startedStream)
        } catch {
            await session.cancel()
            throw map(error)
        }
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let session else { throw StreamingTranscriptionError.notConnected }
        do { try await session.sendAudio(data) } catch { throw map(error) }
    }

    func commit() async throws {
        guard let session else { throw StreamingTranscriptionError.notConnected }
        do { try await session.requestFinish() } catch { throw map(error) }
    }

    func disconnect() async {
        forwardingTask?.cancel()
        forwardingTask = nil
        await session?.cancel()
        session = nil
        eventContinuation?.finish()
        finalContinuation?.finish()
        startedContinuation?.finish()
    }

    private func waitForStarted(_ stream: AsyncStream<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
                throw BailianError.disconnected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw BailianError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func dictionaryHints() throws -> [String: Int] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        let words = (try? modelContext.fetch(descriptor)) ?? []
        var result: [String: Int] = [:]
        for item in words {
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, result[word] == nil { result[word] = 4 }
            if result.count == 80 { break }
        }
        return result
    }

    private func map(_ error: Error) -> Error {
        let error = BailianErrorMapper.map(error)
        switch error {
        case .missingAPIKey: return StreamingTranscriptionError.missingAPIKey
        case .timeout: return StreamingTranscriptionError.timeout
        case .disconnected: return StreamingTranscriptionError.notConnected
        case .network(let detail): return StreamingTranscriptionError.connectionFailed(detail)
        default: return StreamingTranscriptionError.serverError(error.localizedDescription)
        }
    }
}
