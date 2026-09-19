import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct RedactedDiagnosticPackage: Codable, Equatable {
    struct Session: Codable, Equatable {
        let timestamp: Date
        let succeeded: Bool
        let actualProvider: String
        let fallbackPath: String
        let audioDuration: TimeInterval
        let hotwordCount: Int
        let contextTypes: String
        let errorClassification: String
        let transcriptionDuration: TimeInterval?
        let enhancementDuration: TimeInterval?
        let totalDuration: TimeInterval
    }

    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let buildVersion: String
    let operatingSystem: String
    let architecture: String
    let recordingHistoryEnabled: Bool
    let sessions: [Session]
}

@MainActor
enum RedactedDiagnosticExporter {
    static let maximumSessionCount = 500

    static var previewText: String {
        """
        Includes:
        • App/build version, macOS version, and CPU architecture
        • Whether recording history is enabled
        • Up to \(maximumSessionCount) recent session rows
        • Success, Provider, fallback path, durations, hotword count, context source types, and fixed error category

        Excludes:
        • Transcript or enhanced text
        • Audio and file paths
        • API keys, request headers, Workspace ID, and endpoints
        • Raw context, hotword values, URLs, app names, and raw log messages
        """
    }

    static func makePackage(
        metrics: [SessionDiagnosticMetric],
        generatedAt: Date = Date(),
        appVersion: String? = nil,
        buildVersion: String? = nil,
        operatingSystem: String? = nil,
        architecture: String? = nil,
        recordingHistoryEnabled: Bool = AudioHistorySettings.isEnabled
    ) -> RedactedDiagnosticPackage {
        let sessions = metrics
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maximumSessionCount)
            .map { metric in
                RedactedDiagnosticPackage.Session(
                    timestamp: metric.timestamp,
                    succeeded: metric.succeeded,
                    actualProvider: SessionDiagnosticMetric.sanitizedProvider(metric.actualProvider),
                    fallbackPath: SessionDiagnosticMetric.sanitizedRoute(metric.fallbackPath),
                    audioDuration: SessionDiagnosticMetric.sanitizedDuration(metric.audioDuration) ?? 0,
                    hotwordCount: max(0, metric.hotwordCount),
                    contextTypes: {
                        let values = SessionDiagnosticMetric.sanitizedContextTypes(
                            metric.contextTypes.split(separator: ",").map(String.init))
                        return values.isEmpty ? "none" : values.joined(separator: ",")
                    }(),
                    errorClassification: SessionDiagnosticMetric.sanitizedError(metric.errorClassification),
                    transcriptionDuration: SessionDiagnosticMetric.sanitizedDuration(metric.transcriptionDuration),
                    enhancementDuration: SessionDiagnosticMetric.sanitizedDuration(metric.enhancementDuration),
                    totalDuration: SessionDiagnosticMetric.sanitizedDuration(metric.totalDuration) ?? 0
                )
            }
        return RedactedDiagnosticPackage(
            schemaVersion: 1,
            generatedAt: generatedAt,
            appVersion: appVersion
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "Unknown",
            buildVersion: buildVersion
                ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "Unknown",
            operatingSystem: operatingSystem ?? ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture ?? SystemArchitecture.current,
            recordingHistoryEnabled: recordingHistoryEnabled,
            sessions: Array(sessions)
        )
    }

    static func encodedPackage(metrics: [SessionDiagnosticMetric]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makePackage(metrics: metrics))
    }

    static func export(from modelContext: ModelContext) throws -> URL? {
        let metrics = try modelContext.fetch(FetchDescriptor<SessionDiagnosticMetric>())
        let data = try encodedPackage(metrics: metrics)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "my-voice-redacted-diagnostics.json"
        panel.title = String(localized: "Export Redacted Diagnostics")
        panel.message = String(localized: "Choose where to save the reviewed diagnostic package.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}
