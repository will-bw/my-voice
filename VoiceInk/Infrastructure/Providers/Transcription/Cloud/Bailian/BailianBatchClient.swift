import Foundation
import os

struct BailianRecognitionHints: Equatable, Sendable {
    let vocabulary: [String: Int]
    let languageHints: [String]
    let context: String?

    init(vocabulary: [String: Int] = [:], languageHints: [String] = [], context: String? = nil) throws {
        guard vocabulary.count <= 2_000 else {
            throw BailianError.misconfigured("即时热词不得超过 2000 个")
        }
        let superHotwordCount = vocabulary.values.filter { $0 == 50 }.count
        guard superHotwordCount <= 50 else {
            throw BailianError.misconfigured("超级热词不得超过 50 个")
        }
        guard vocabulary.values.allSatisfy({ (1...5).contains($0) || $0 == 50 }) else {
            throw BailianError.misconfigured("热词权重必须为 1～5 或 50")
        }
        guard languageHints.count <= 4 else {
            throw BailianError.misconfigured("语言提示不得超过 4 个")
        }
        let trimmedContext = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmedContext?.count ?? 0) <= 400 else {
            throw BailianError.misconfigured("上下文不得超过 400 个字符")
        }

        self.vocabulary = vocabulary
        self.languageHints = languageHints
        self.context = trimmedContext?.isEmpty == true ? nil : trimmedContext
    }
}

struct BailianBatchResult: Equatable, Sendable {
    let text: String
    let requestID: String?
}

struct BailianDiagnosticEvent: Equatable, Sendable {
    let provider: String
    let region: BailianRegion
    let operation: String
    let statusCode: Int?
    let errorCategory: String?
}

actor BailianBatchClient {
    private let configuration: BailianConfiguration
    private let transport: any BailianHTTPTransport
    private let healthStore: BailianProviderHealthStore
    private let logger = Logger(subsystem: "com.will.myvoice", category: "BailianProvider")

    init(
        configuration: BailianConfiguration,
        transport: any BailianHTTPTransport = BailianURLSessionHTTPTransport(),
        healthStore: BailianProviderHealthStore = .shared
    ) {
        self.configuration = configuration
        self.transport = transport
        self.healthStore = healthStore
    }

    func transcribe(
        audioData: Data,
        fileName: String,
        apiKey: String,
        hints: BailianRecognitionHints,
        timeout: TimeInterval
    ) async throws -> BailianBatchResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BailianError.missingAPIKey
        }
        do {
            try await healthStore.ensureAttemptAllowed()
            let request = try makeRequest(
                audioData: audioData,
                fileName: fileName,
                apiKey: apiKey,
                hints: hints,
                timeout: timeout
            )
            let (data, response) = try await transport.data(for: request)
            guard (200...299).contains(response.statusCode) else {
                throw BailianErrorMapper.map(statusCode: response.statusCode, responseBody: data)
            }
            let result = try parseResponse(data)
            await healthStore.markHealthy()
            logger.info(
                "Bailian batch succeeded region=\(self.configuration.region.rawValue, privacy: .public) status=\(response.statusCode, privacy: .public)"
            )
            return result
        } catch {
            let mapped = BailianErrorMapper.map(error)
            await healthStore.record(mapped)
            logger.error(
                "Bailian batch failed region=\(self.configuration.region.rawValue, privacy: .public) category=\(String(describing: mapped), privacy: .public)"
            )
            throw mapped
        }
    }

    func makeRequest(
        audioData: Data,
        fileName: String,
        apiKey: String,
        hints: BailianRecognitionHints,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let format = Self.audioFormat(fileName: fileName)
        let mimeType = format == "wav" ? "audio/wav" : "application/octet-stream"
        let dataURL = "data:\(mimeType);base64,\(audioData.base64EncodedString())"

        var messages: [[String: Any]] = []
        if let context = hints.context {
            messages.append([
                "role": "user",
                "content": [["type": "input_text", "text": context]],
            ])
        }
        messages.append([
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": ["data": dataURL],
            ]],
        ])

        var parameters: [String: Any] = [
            "format": format,
            "sample_rate": "16000",
        ]
        if !hints.vocabulary.isEmpty { parameters["vocabulary"] = hints.vocabulary }
        if !hints.languageHints.isEmpty { parameters["language_hints"] = hints.languageHints }

        let body: [String: Any] = [
            "model": BailianConfiguration.batchModel,
            "input": ["messages": messages],
            "parameters": parameters,
        ]

        var request = URLRequest(url: configuration.httpEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.setValue("my-voice/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseResponse(_ data: Data) throws -> BailianBatchResult {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = object["output"] as? [String: Any]
        else {
            throw BailianError.invalidResponse("缺少 output")
        }
        let directText = output["text"] as? String
        let nestedText = ((output["output"] as? [String: Any])?["sentence"] as? [String: Any])?["text"] as? String
        let text = (directText ?? nestedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BailianError.emptyFinal }
        return BailianBatchResult(text: text, requestID: object["request_id"] as? String)
    }

    private static func audioFormat(fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return ext.isEmpty ? "wav" : ext
    }
}
