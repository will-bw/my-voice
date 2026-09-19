import Foundation
import XCTest
@testable import VoiceInk

final class HistoryAndDiagnosticsTests: XCTestCase {
    func testRecordingHistoryIsOffForFreshSettings() throws {
        let suite = "HistoryAndDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AudioHistorySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(AudioHistorySettings.defaultRetentionDays, 7)
        XCTAssertEqual(AudioHistorySettings.defaultMaximumBytes, 1_073_741_824)
        XCTAssertTrue(AudioHistorySettings.temporaryRecordingsDirectory.path.contains("SessionRecordings"))
        XCTAssertNotEqual(
            AudioHistorySettings.temporaryRecordingsDirectory,
            AudioHistorySettings.defaultRecordingsDirectory
        )
    }

    func testCrashRecoveryRemovesStaleTemporaryRecordings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryAndDiagnosticsTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("one.wav"))
        try Data([2]).write(to: directory.appendingPathComponent("two.wav"))

        let result = AudioHistorySettings.removeStaleTemporaryRecordings(directory: directory)

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCleanupUsesAgeOrCapacityAndDeletesOldestFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = AudioHistoryFile(
            id: UUID(), timestamp: now.addingTimeInterval(-8 * 86_400), size: 20, isProtected: false)
        let first = AudioHistoryFile(
            id: UUID(), timestamp: now.addingTimeInterval(-300), size: 60, isProtected: false)
        let second = AudioHistoryFile(
            id: UUID(), timestamp: now.addingTimeInterval(-200), size: 60, isProtected: false)

        let deleted = AudioHistoryCleanupPlanner.deletionIDs(
            files: [second, old, first],
            now: now,
            retentionDays: 7,
            maximumBytes: 100
        )

        XCTAssertEqual(deleted, Set([old.id, first.id]))
    }

    func testCleanupNeverDeletesProtectedActiveFile() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let active = AudioHistoryFile(
            id: UUID(), timestamp: now.addingTimeInterval(-10 * 86_400), size: 500, isProtected: true)
        let completed = AudioHistoryFile(
            id: UUID(), timestamp: now.addingTimeInterval(-100), size: 50, isProtected: false)

        let deleted = AudioHistoryCleanupPlanner.deletionIDs(
            files: [active, completed],
            now: now,
            retentionDays: 7,
            maximumBytes: 100
        )

        XCTAssertFalse(deleted.contains(active.id))
        XCTAssertTrue(deleted.contains(completed.id))
    }

    @MainActor
    func testDiagnosticMetricStoresOnlyWhitelistedCategoriesAndCounts() {
        let metric = SessionDiagnosticMetric(
            transcriptionId: UUID(),
            succeeded: false,
            actualProvider: "secret-provider-key",
            fallbackPath: "private-route",
            audioDuration: 3.2,
            hotwordCount: 4,
            contextTypes: ["clipboard", "raw-context: private project", "selected-text"],
            errorClassification: "Authorization: Bearer secret",
            transcriptionDuration: 1.1,
            enhancementDuration: nil,
            totalDuration: 1.4
        )

        XCTAssertEqual(metric.actualProvider, "unknown")
        XCTAssertEqual(metric.fallbackPath, TranscriptionRoute.selectedModel.rawValue)
        XCTAssertEqual(metric.contextTypes, "clipboard,selected-text")
        XCTAssertEqual(metric.errorClassification, "unknown")
        XCTAssertEqual(metric.hotwordCount, 4)
    }

    @MainActor
    func testRedactedDiagnosticExportContainsOnlyWhitelistedSessionFields() throws {
        let metric = SessionDiagnosticMetric(
            transcriptionId: UUID(),
            timestamp: Date(timeIntervalSince1970: 2_000_000),
            succeeded: false,
            actualProvider: "provider-secret-value",
            fallbackPath: "private-route",
            audioDuration: 1.5,
            hotwordCount: 2,
            contextTypes: ["clipboard", "raw secret context"],
            errorClassification: "Bearer secret-token",
            transcriptionDuration: 0.7,
            enhancementDuration: nil,
            totalDuration: 1.0
        )
        // SwiftData properties remain mutable after initialization, so the exporter must
        // enforce the allowlist again instead of trusting stored values blindly.
        metric.actualProvider = "mutated-provider-secret"
        metric.fallbackPath = "mutated-route-secret"
        metric.contextTypes = "clipboard,mutated-context-secret"
        metric.errorClassification = "mutated-error-secret"
        metric.audioDuration = .infinity
        metric.hotwordCount = -2
        metric.transcriptionDuration = .nan
        metric.totalDuration = -4
        let package = RedactedDiagnosticExporter.makePackage(
            metrics: [metric],
            generatedAt: Date(timeIntervalSince1970: 3_000_000),
            appVersion: "test",
            buildVersion: "test",
            operatingSystem: "test",
            architecture: "test",
            recordingHistoryEnabled: false
        )
        let data = try JSONEncoder().encode(package)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(package.sessions.count, 1)
        XCTAssertEqual(package.sessions[0].actualProvider, "unknown")
        XCTAssertEqual(package.sessions[0].contextTypes, "clipboard")
        XCTAssertEqual(package.sessions[0].errorClassification, "unknown")
        XCTAssertFalse(text.contains("provider-secret-value"))
        XCTAssertFalse(text.contains("raw secret context"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("mutated-"))
        XCTAssertEqual(package.sessions[0].audioDuration, 0)
        XCTAssertEqual(package.sessions[0].hotwordCount, 0)
        XCTAssertNil(package.sessions[0].transcriptionDuration)
        XCTAssertEqual(package.sessions[0].totalDuration, 0)
    }
}
