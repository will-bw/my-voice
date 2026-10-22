import Foundation
import SwiftData

final class BailianStreamingProvider: StreamingTranscriptionProvider {
    private let modelContext: ModelContext
    private var session: BailianStreamingSession?
    private var forwardingTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    private var finalContinuation: AsyncStream<String>.Continuation?
    private var recognitionHints: RecognitionHintSnapshot?

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
    }

    func configureRecognitionHints(_ snapshot: RecognitionHintSnapshot?) {
        recognitionHints = snapshot
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

        let vocabulary: [String: Int]
        if let configuredVocabulary = recognitionHints?.vocabulary {
            vocabulary = configuredVocabulary
        } else {
            vocabulary = try dictionaryHints()
        }
        let hints = try BailianRecognitionHints(
            vocabulary: vocabulary,
            languageHints: recognitionHints?.languageHints
                ?? ((language == nil || language == "auto") ? [] : [language!]),
            context: recognitionHints?.context
        )
        let session = BailianStreamingSession(
            configuration: configuration,
            transport: BailianURLSessionWebSocketTransport()
        )
        self.session = session

        forwardingTask = Task { [weak self] in
            for await output in session.outputs {
                guard let self else { return }
                switch output {
                case .sessionStarted:
                    self.eventContinuation?.yield(.sessionStarted)
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
                }
            }
        }

        do {
            try await session.connectAndWaitForStarted(apiKey: apiKey, hints: hints)
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
        case .emptyFinal: return StreamingTranscriptionError.noSpeech
        case .canceled: return StreamingTranscriptionError.cancelled
        case .invalidCredential: return StreamingTranscriptionError.invalidCredential
        case .misconfigured(let detail):
            return StreamingTranscriptionError.misconfigured(detail)
        case .requestRejected:
            return StreamingTranscriptionError.serverError(error.localizedDescription)
        case .protocolViolation, .invalidResponse:
            return StreamingTranscriptionError.connectionFailed(error.localizedDescription)
        case .rateLimited: return StreamingTranscriptionError.rateLimited
        case .server: return StreamingTranscriptionError.serviceUnavailable
        case .network(let detail): return StreamingTranscriptionError.connectionFailed(detail)
        }
    }
}
