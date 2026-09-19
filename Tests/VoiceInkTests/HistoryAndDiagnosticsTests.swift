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
}
