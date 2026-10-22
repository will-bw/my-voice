import Foundation
import SwiftData

/// Redacted per-session diagnostics. This model never stores transcript text,
/// audio, context content, hotword values, request headers, or credentials.
@Model
final class SessionDiagnosticMetric {
    @Attribute(.unique) var transcriptionId: UUID = UUID()
    var timestamp: Date = Date()
    var succeeded: Bool = false
    var actualProvider: String = "unknown"
    var fallbackPath: String = "selected-model"
    var audioDuration: TimeInterval = 0
    var hotwordCount: Int = 0
    var contextTypes: String = "none"
    var errorClassification: String = "none"
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var totalDuration: TimeInterval = 0

    init(
        transcriptionId: UUID,
        timestamp: Date = Date(),
        succeeded: Bool,
        actualProvider: String,
        fallbackPath: String,
        audioDuration: TimeInterval,
        hotwordCount: Int,
        contextTypes: [String],
        errorClassification: String,
        transcriptionDuration: TimeInterval?,
        enhancementDuration: TimeInterval?,
        totalDuration: TimeInterval
    ) {
        self.transcriptionId = transcriptionId
        self.timestamp = timestamp
        self.succeeded = succeeded
        self.actualProvider = Self.sanitizedProvider(actualProvider)
        self.fallbackPath = Self.sanitizedRoute(fallbackPath)
        self.audioDuration = Self.sanitizedDuration(audioDuration) ?? 0
        self.hotwordCount = max(0, hotwordCount)
        let allowedContexts = Self.sanitizedContextTypes(contextTypes)
        self.contextTypes = allowedContexts.isEmpty ? "none" : allowedContexts.joined(separator: ",")
        self.errorClassification = Self.sanitizedError(errorClassification)
        self.transcriptionDuration = Self.sanitizedDuration(transcriptionDuration)
        self.enhancementDuration = Self.sanitizedDuration(enhancementDuration)
        self.totalDuration = Self.sanitizedDuration(totalDuration) ?? 0
    }

    private static let providers: Set<String> = Set(ModelProvider.allCases.map(\.rawValue)).union(["unknown"])
    private static let routes: Set<String> = Set(TranscriptionRoute.allCases.map(\.rawValue))
    private static let contexts: Set<String> = ["selected-text", "clipboard", "screen-text"]
    private static let errors: Set<String> = [
        "none", "authentication", "authorization", "rate-limited", "server", "timeout", "network",
        "disconnected", "canceled", "invalid-response", "configuration", "no-speech", "local-model", "unknown",
    ]

    static func sanitizedProvider(_ value: String) -> String {
        providers.contains(value) ? value : "unknown"
    }

    static func sanitizedRoute(_ value: String) -> String {
        routes.contains(value) ? value : TranscriptionRoute.selectedModel.rawValue
    }

    static func sanitizedContextTypes(_ values: [String]) -> [String] {
        Array(Set(values.filter(contexts.contains))).sorted()
    }

    static func sanitizedError(_ value: String) -> String {
        errors.contains(value) ? value : "unknown"
    }

    static func sanitizedDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

enum TranscriptionDiagnosticErrorClassifier {
    static func classify(_ error: Error) -> String {
        if let bailian = error as? BailianError {
            switch bailian {
            case .missingAPIKey: return "configuration"
            case .invalidCredential(let statusCode):
                return statusCode == 403 ? "authorization" : "authentication"
            case .rateLimited: return "rate-limited"
            case .server: return "server"
            case .timeout: return "timeout"
            case .network: return "network"
            case .disconnected: return "disconnected"
            case .canceled: return "canceled"
            case .invalidResponse, .emptyFinal, .protocolViolation, .requestRejected: return "invalid-response"
            case .misconfigured: return "configuration"
            }
        }
        if let cloud = error as? CloudTranscriptionError {
            switch cloud {
            case .missingAPIKey, .unsupportedProvider, .unsupportedModel, .dataEncodingError:
                return "configuration"
            case .invalidAPIKey: return "authentication"
            case .audioFileNotFound: return "configuration"
            case .apiRequestFailed(let statusCode, _):
                if statusCode == 401 { return "authentication" }
                if statusCode == 403 { return "authorization" }
                if statusCode == 429 { return "rate-limited" }
                if statusCode >= 500 { return "server" }
                return "invalid-response"
            case .networkError(let underlying): return classify(underlying)
            case .noTranscriptionReturned: return "no-speech"
            }
        }
        if let streaming = error as? StreamingTranscriptionError {
            switch streaming {
            case .missingAPIKey, .misconfigured: return "configuration"
            case .invalidCredential: return "authentication"
            case .rateLimited: return "rate-limited"
            case .timeout: return "timeout"
            case .connectionFailed, .notConnected: return "network"
            case .serverError, .serviceUnavailable: return "server"
            case .cancelled: return "canceled"
            case .noSpeech: return "no-speech"
            case .audioConversionFailed, .audioBackpressureExceeded: return "invalid-response"
            }
        }
        if error is CancellationError { return "canceled" }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "timeout" : "network"
        }
        return "unknown"
    }
}
