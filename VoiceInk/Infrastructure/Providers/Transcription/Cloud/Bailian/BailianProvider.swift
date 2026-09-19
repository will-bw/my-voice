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
        let configuration = try BailianConfigurationStore.shared.load()
        var vocabulary: [String: Int] = [:]
        for candidate in customVocabulary {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, vocabulary[word] == nil { vocabulary[word] = 4 }
            if vocabulary.count == 80 { break }
        }
        let hints = try BailianRecognitionHints(
            vocabulary: vocabulary,
            languageHints: language.map { [$0] } ?? []
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
            await BailianProviderHealthStore.shared.reset()
            let configuration = try BailianConfigurationStore.shared.load()
            let client = BailianBatchClient(configuration: configuration)
            _ = try await client.transcribe(
                audioData: Self.silentWAV,
                fileName: "connection-check.wav",
                apiKey: key,
                hints: BailianRecognitionHints(languageHints: ["zh"]),
                timeout: 15
            )
            return (true, nil)
        } catch BailianError.emptyFinal {
            // A silent probe can legitimately produce no transcript. Reaching a
            // successful response still proves that the endpoint accepted the
            // workspace and credential.
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private var supportedLanguages: [String: String] {
        var values = LanguageDictionary.forCodes(languageCodes ?? [])
        values["auto"] = "Auto"
        return values
    }

    private static let silentWAV: Data = {
        // 100 ms, 16 kHz, mono, signed 16-bit PCM. A non-empty WAV avoids
        // providers rejecting the connection probe as a malformed audio file.
        var bytes: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0xA4, 0x0C, 0x00, 0x00,
            0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20,
            0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00,
            0x02, 0x00, 0x10, 0x00, 0x64, 0x61, 0x74, 0x61,
            0x80, 0x0C, 0x00, 0x00,
        ]
        bytes.append(contentsOf: repeatElement(0, count: 3_200))
        return Data(bytes)
    }()
}
