import Foundation
import os

enum TranscriptionRoute: String, Codable, Sendable {
    case selectedModel = "selected-model"
    case streaming = "streaming"
    case batchFallback = "batch-fallback"
    case localFallback = "local-fallback"

    var displayName: String {
        switch self {
        case .selectedModel: String(localized: "Selected model")
        case .streaming: String(localized: "Streaming")
        case .batchFallback: String(localized: "Batch fallback")
        case .localFallback: String(localized: "Local fallback")
        }
    }
}

struct TranscriptionSessionResult {
    let text: String
    let route: TranscriptionRoute
    let modelDisplayName: String
}

struct LocalTranscriptionFallback {
    let service: TranscriptionService
    let model: any TranscriptionModel
}

/// Encapsulates a single recording-to-transcription lifecycle (streaming or file-based).
@MainActor
protocol TranscriptionSession: AnyObject {
    /// Prepares the session. Returns an audio chunk callback for streaming, or nil for file-based.
    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)?

    /// Called after recording stops. Returns the final transcribed text.
    func transcribe(audioURL: URL) async throws -> TranscriptionSessionResult

    /// Cancel the session and clean up resources.
    func cancel()
}

// MARK: - File-Based Session

/// File-based session: records to file, uploads after stop.
@MainActor
final class FileTranscriptionSession: TranscriptionSession {
    private let service: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults

    init(service: TranscriptionService) {
        self.service = service
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        self.model = configuration.model
        self.context = configuration.requestContext.scoped(to: configuration.model)
        return nil
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionSessionResult {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        let text = try await service.transcribe(audioURL: audioURL, model: model, context: context)
        return TranscriptionSessionResult(text: text, route: .selectedModel, modelDisplayName: model.displayName)
    }

    func cancel() {
        // No-op for file-based transcription
    }
}

// MARK: - Streaming Session

/// Streaming session with automatic fallback to file-based upload on failure.
@MainActor
final class StreamingTranscriptionSession: TranscriptionSession {
    private let streamingService: any StreamingTranscriptionServicing
    private let batchFallbackService: TranscriptionService
    private let batchFallbackModel: any TranscriptionModel
    private let localFallback: LocalTranscriptionFallback?
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var streamingFailed = false
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var isCancelled = false
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionSession")

    init(
        streamingService: any StreamingTranscriptionServicing,
        batchFallbackService: TranscriptionService,
        batchFallbackModel: any TranscriptionModel,
        localFallback: LocalTranscriptionFallback?
    ) {
        self.streamingService = streamingService
        self.batchFallbackService = batchFallbackService
        self.batchFallbackModel = batchFallbackModel
        self.localFallback = localFallback
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        let model = configuration.model
        let context = configuration.requestContext.scoped(to: model)

        self.model = model
        self.context = context
        isCancelled = false
        streamingFailed = false
        logger.notice("Streaming session prepare model=\(model.displayName, privacy: .public)")

        // Return callback immediately; WebSocket connects in background
        let service = streamingService
        let callback: (Data) -> Void = { [weak service] data in
            service?.sendAudioChunk(data)
        }

        startupTask?.cancel()
        let taskID = UUID()
        startupTaskID = taskID
        startupTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.startupTaskID == taskID {
                    self.startupTask = nil
                    self.startupTaskID = nil
                }
            }
            guard !Task.isCancelled else { return }

            do {
                let start = Date()
                try await self.streamingService.startStreaming(model: model, context: context)
                guard !Task.isCancelled else {
                    self.streamingService.cancel()
                    return
                }
                self.logger.notice(
                    "Streaming session connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
                )
            } catch is CancellationError {
                self.streamingService.cancel()
            } catch {
                guard !Task.isCancelled else { return }
                let desc = error.localizedDescription
                self.logger.error("❌ Failed to start streaming, will fall back to batch: \(desc, privacy: .public)")
                self.streamingFailed = true
            }
        }

        return callback
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionSessionResult {
        guard let model = model else {
            throw VoiceInkEngineError.transcriptionFailed
        }
        try ensureNotCancelled()

        if let startupTask {
            await startupTask.value
            try ensureNotCancelled()
        }

        if !streamingFailed {
            do {
                let start = Date()
                logger.notice("Streaming stop/transcribe started model=\(model.displayName, privacy: .public)")
                let result = try await streamingService.stopAndFinalize()
                switch result {
                case .finalized(let text):
                    logger.notice(
                        "Streaming transcript received elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
                    )
                    return TranscriptionSessionResult(
                        text: text,
                        route: .streaming,
                        modelDisplayName: model.displayName
                    )
                case .requiresBatchFallback:
                    logger.notice("Streaming provider requested full batch transcription")
                }
            } catch {
                if shouldStopWithoutFallback(error) { throw error }
                logger.error("❌ Streaming failed, falling back to batch: \(error, privacy: .public)")
                startupTask?.cancel()
                startupTask = nil
                startupTaskID = nil
                streamingService.cancel()
            }
        } else {
            startupTask?.cancel()
            startupTask = nil
            startupTaskID = nil
            streamingService.cancel()
        }

        try ensureNotCancelled()
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CloudTranscriptionError.audioFileNotFound
        }

        let fallbackStart = Date()
        logger.notice(
            "Using batch fallback for \(self.batchFallbackModel.displayName, privacy: .public) file=\(audioURL.lastPathComponent, privacy: .public)"
        )
        do {
            let text = try await batchFallbackService.transcribe(
                audioURL: audioURL,
                model: batchFallbackModel,
                context: context.scoped(to: batchFallbackModel)
            )
            logger.notice(
                "Batch fallback completed elapsed=\(Date().timeIntervalSince(fallbackStart), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
            )
            return TranscriptionSessionResult(
                text: text,
                route: .batchFallback,
                modelDisplayName: batchFallbackModel.displayName
            )
        } catch {
            if shouldStopWithoutFallback(error) || !shouldUseLocalFallback(after: error) { throw error }
            return try await transcribeLocally(audioURL: audioURL)
        }
    }

    func cancel() {
        isCancelled = true
        startupTask?.cancel()
        startupTask = nil
        startupTaskID = nil
        streamingService.cancel()
    }

    private func transcribeLocally(audioURL: URL) async throws -> TranscriptionSessionResult {
        try ensureNotCancelled()
        guard let localFallback else { throw VoiceInkEngineError.transcriptionFailed }

        let start = Date()
        logger.notice("Using local fallback model=\(localFallback.model.displayName, privacy: .public)")
        let text = try await localFallback.service.transcribe(
            audioURL: audioURL,
            model: localFallback.model,
            context: context.scoped(to: localFallback.model)
        )
        try ensureNotCancelled()
        logger.notice(
            "Local fallback completed elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s chars=\(text.count, privacy: .public)"
        )
        return TranscriptionSessionResult(
            text: text,
            route: .localFallback,
            modelDisplayName: localFallback.model.displayName
        )
    }

    private func ensureNotCancelled() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    private func shouldStopWithoutFallback(_ error: Error) -> Bool {
        if isCancelled || error is CancellationError { return true }
        if let streamingError = error as? StreamingTranscriptionError {
            switch streamingError {
            case .cancelled, .noSpeech:
                return true
            default:
                return false
            }
        }
        if let cloudError = error as? CloudTranscriptionError {
            switch cloudError {
            case .audioFileNotFound, .noTranscriptionReturned:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func shouldUseLocalFallback(after error: Error) -> Bool {
        guard localFallback != nil else { return false }
        if let cloudError = error as? CloudTranscriptionError {
            switch cloudError {
            case .audioFileNotFound, .noTranscriptionReturned:
                return false
            default:
                return true
            }
        }
        return true
    }
}
