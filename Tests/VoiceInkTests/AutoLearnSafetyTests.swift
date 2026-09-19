import SwiftData
import XCTest
@testable import VoiceInk

final class AutoLearnSafetyTests: XCTestCase {
    func testManualReviewIsDefaultForFreshSettings() throws {
        let suite = "AutoLearnSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AutoLearnSettings.reviewSchedule(defaults: defaults), .manually)
    }

    func testCorrectionGateRejectsStyleAndBroadRewriteButKeepsLocalCorrection() {
        XCTAssertTrue(CorrectionDiffEngine.candidates(from: .init(
            original: "OpenAI",
            corrected: "openai"
        )).isEmpty)
        XCTAssertTrue(CorrectionDiffEngine.candidates(from: .init(
            original: "hello world",
            corrected: "hello, world!"
        )).isEmpty)
        XCTAssertTrue(CorrectionDiffEngine.candidates(from: .init(
            original: "we should completely rewrite this whole sentence before sending it",
            corrected: "please send a concise and polished update to everyone tomorrow"
        )).isEmpty)

        let local = CorrectionDiffEngine.candidates(from: .init(
            original: "Ship the Marrow build today",
            corrected: "Ship the Morrow build today"
        ))
        XCTAssertEqual(local.count, 1)
    }

    func testFinalSnapshotRejectsAmbiguousAnchorsOutsideInsertedRange() {
        let snapshot = AutoLearnFieldSnapshot(
            baselineFieldText: "same Marrow same ",
            finalFieldText: "same Morrow same ",
            pastedRange: NSRange(location: 5, length: 6),
            originalPastedText: "Marrow"
        )
        XCTAssertNil(FinalSnapshotDiffEngine.revision(from: snapshot))
    }

    @MainActor
    func testFeedbackMigrationAddsSideRowsWithoutChangingRules() throws {
        let schema = Schema([
            VocabularyWord.self,
            AdaptiveTermMetadata.self,
            WordReplacement.self,
            CorrectionFeedbackMetadata.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(WordReplacement(originalText: "Marrow, Morro", replacementText: "Morrow"))
        try context.save()

        let first = try CorrectionFeedbackMetadataMigration.run(in: context)
        let second = try CorrectionFeedbackMetadataMigration.run(in: context)
        let rules = try context.fetch(FetchDescriptor<WordReplacement>())
        let feedback = try context.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())

        XCTAssertEqual(first.createdCount, 2)
        XCTAssertEqual(second.createdCount, 0)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(feedback.count, 2)
        XCTAssertTrue(feedback.allSatisfy(\.isEnabled))
    }

    @MainActor
    func testApprovalUndoAndRejectionUpdateFeedbackAndAdaptiveSignals() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)
        let candidateID = UUID()
        let candidate = AutoLearnReviewCandidate(
            candidateID: candidateID,
            originalText: "Marrow",
            correctedText: "Morrow"
        )
        let decision = AutoLearnReviewDecision(
            candidateID: candidateID,
            learningAction: .addReplacementAndVocabulary,
            incorrectTextToReplace: "Marrow",
            correctedVocabularyTerm: "Morrow"
        )

        let summary = try await store.apply([decision], candidates: [candidate])
        XCTAssertEqual(summary.createdCount, 1)
        XCTAssertEqual(summary.vocabularyCount, 1)
        let applied = try XCTUnwrap(summary.learnedCorrections.first)
        try await store.undo(applied)

        let proposal = AutoLearnReviewProposal(
            id: UUID(),
            candidateID: UUID(),
            originalText: "Marrow",
            correctedText: "Morrow",
            learningAction: .addReplacementAndVocabulary,
            incorrectTextToReplace: "Marrow",
            correctedVocabularyTerm: "Morrow"
        )
        try await store.recordRejected([proposal])

        let feedback = try container.mainContext.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())
        let metadata = try XCTUnwrap(feedback.first)
        XCTAssertEqual(metadata.acceptedCount, 1)
        XCTAssertEqual(metadata.undoCount, 1)
        XCTAssertEqual(metadata.rejectedCount, 1)
        XCTAssertFalse(metadata.isEnabled)
        XCTAssertLessThan(metadata.confidence, 0.5)

        let adaptive = try container.mainContext.fetch(FetchDescriptor<AdaptiveTermMetadata>())
        XCTAssertEqual(adaptive.first?.correctionCount, 1)
        XCTAssertEqual(adaptive.first?.positiveFeedbackCount, 1)
        XCTAssertEqual(adaptive.first?.negativeFeedbackCount, 2)
    }

    @MainActor
    func testFourReviewActionsHaveDistinctPersistenceEffects() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)
        let candidates = [
            AutoLearnReviewCandidate(candidateID: UUID(), originalText: "Marrow", correctedText: "Morrow"),
            AutoLearnReviewCandidate(candidateID: UUID(), originalText: "open aye", correctedText: "OpenAI"),
            AutoLearnReviewCandidate(candidateID: UUID(), originalText: "Codex", correctedText: "Codex"),
            AutoLearnReviewCandidate(candidateID: UUID(), originalText: "good morning", correctedText: "hello"),
        ]
        let decisions = [
            AutoLearnReviewDecision(
                candidateID: candidates[0].candidateID,
                learningAction: .addReplacementAndVocabulary,
                incorrectTextToReplace: "Marrow",
                correctedVocabularyTerm: "Morrow"
            ),
            AutoLearnReviewDecision(
                candidateID: candidates[1].candidateID,
                learningAction: .addReplacementOnly,
                incorrectTextToReplace: "open aye",
                correctedVocabularyTerm: "OpenAI"
            ),
            AutoLearnReviewDecision(
                candidateID: candidates[2].candidateID,
                learningAction: .addVocabularyOnly,
                incorrectTextToReplace: nil,
                correctedVocabularyTerm: "Codex"
            ),
            AutoLearnReviewDecision(
                candidateID: candidates[3].candidateID,
                learningAction: .rejectCorrection,
                incorrectTextToReplace: nil,
                correctedVocabularyTerm: nil
            ),
        ]

        let summary = try await store.apply(decisions, candidates: candidates)
        XCTAssertEqual(summary.createdCount, 2)
        XCTAssertEqual(summary.vocabularyCount, 2)
        XCTAssertEqual(summary.learnedCorrections.count, 3)

        let context = container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordReplacement>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VocabularyWord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CorrectionFeedbackMetadata>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AdaptiveTermMetadata>()).count, 3)
    }

    @MainActor
    func testExactUserRevertDisablesRuleAfterTwoSignalsAndStopsApplication() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(WordReplacement(originalText: "Marrow", replacementText: "Morrow"))
        try context.save()
        let store = WordReplacementStore(modelContainer: container)
        let revision = AutoLearnRevision(
            original: "Ship Morrow today",
            corrected: "Ship Marrow today"
        )

        let firstRevertCount = try await store.recordUserReverts(in: revision)
        let secondRevertCount = try await store.recordUserReverts(in: revision)
        XCTAssertEqual(firstRevertCount, 1)
        XCTAssertEqual(secondRevertCount, 1)

        let feedback = try context.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())
        XCTAssertEqual(feedback.first?.revertCount, 2)
        XCTAssertFalse(feedback.first?.isEnabled ?? true)
        XCTAssertEqual(
            WordReplacementService.shared.applyReplacements(
                to: "Ship Marrow today",
                using: context
            ),
            "Ship Marrow today"
        )
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VocabularyWord.self,
            AdaptiveTermMetadata.self,
            WordReplacement.self,
            CorrectionFeedbackMetadata.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }
}
