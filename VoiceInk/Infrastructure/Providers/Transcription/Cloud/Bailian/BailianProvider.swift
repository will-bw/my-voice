import Foundation
import SwiftData

struct BailianProvider: CloudProvider {
    let modelProvider: ModelProvider = .bailian
    let providerKey = "Bailian"
    let languageCodes: [String]? = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi", "ar", "fr", "de", "es", "pt",
        "ru", "it", "nl", "sv", "da", "fi", "no", "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk",
    ]
    let includesAutoDetect = true

    var models: [CloudModel] {
        [
            CloudModel(
                name: BailianConfiguration.streamingModel,
                displayName: "Qwen Audio 3.0 ASR Flash Streaming",
                description: "Bailian streaming ASR with request-scoped hotwords and context",
                provider: .bailian,
                isMultilingual: true,
                supportsStreaming: true,
                supportedLanguages: supportedLanguages
            ),
            CloudModel(
                name: BailianConfiguration.batchModel,
                displayName: "Qwen Audio 3.0 ASR Flash",
                description: "Bailian synchronous short-audio transcription",
                provider: .bailian,
                isMultilingual: true,
                supportsStreaming: false,
                supportedLanguages: supportedLanguages
            ),
        ]
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        language: String?,
        customVocabulary: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            language: language,
            customVocabulary: customVocabulary,
            recognitionHints: nil,
            timeout: timeout
        )
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        language: String?,
        customVocabulary: [String],
        recognitionHints: RecognitionHintSnapshot?,
        timeout: TimeInterval
    ) async throws -> String {
        let configuration = try BailianConfigurationStore.shared.load()
        var vocabulary: [String: Int] = [:]
        for candidate in customVocabulary {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, vocabulary[word] == nil { vocabulary[word] = 4 }
            if vocabulary.count == 80 { break }
        }
        let hints = try BailianRecognitionHints(
            vocabulary: recognitionHints?.vocabulary ?? vocabulary,
            languageHints: recognitionHints?.languageHints ?? language.map { [$0] } ?? [],
            context: recognitionHints?.context
        )
        let client = BailianBatchClient(configuration: configuration)
        return try await client.transcribe(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            hints: hints,
            timeout: timeout
        ).text
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        BailianStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        do {
            let configuration = try BailianConfigurationStore.shared.load()
            return await verifyAPIKey(key, configuration: configuration)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func verifyAPIKey(
        _ key: String,
        configuration: BailianConfiguration
    ) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(
            key,
            configuration: configuration,
            transport: BailianURLSessionWebSocketTransport(),
            healthStore: .shared
        )
    }

    func verifyAPIKey(
        _ key: String,
        configuration: BailianConfiguration,
        transport: any BailianWebSocketTransport,
        healthStore: BailianProviderHealthStore,
        timeout: Duration = .seconds(15)
    ) async -> (isValid: Bool, errorMessage: String?) {
        let session = BailianStreamingSession(
            configuration: configuration,
            transport: transport,
            healthStore: healthStore
        )
        do {
            await healthStore.reset()
            try await session.connect(
                apiKey: key,
                hints: BailianRecognitionHints(languageHints: ["zh"])
            )
            try await waitForSessionStarted(session.outputs, timeout: timeout)
            await session.cancel()
            return (true, nil)
        } catch {
            await session.cancel()
            return (false, error.localizedDescription)
        }
    }

    private var supportedLanguages: [String: String] {
        var values = LanguageDictionary.forCodes(languageCodes ?? [])
        values["auto"] = "Auto"
        return values
    }

    private func waitForSessionStarted(
        _ outputs: AsyncStream<BailianStreamingOutput>,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await output in outputs {
                    switch output {
                    case .sessionStarted:
                        return
                    case .failed(let error):
                        throw error
                    case .partial, .committed, .final:
                        continue
                    }
                }
                throw BailianError.disconnected
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BailianError.timeout
            }
            guard let result = try await group.next() else {
                throw BailianError.disconnected
            }
            group.cancelAll()
            return result
        }
    }
}
