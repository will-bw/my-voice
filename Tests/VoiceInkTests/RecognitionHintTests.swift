import SwiftData
import XCTest
@testable import VoiceInk

final class RecognitionHintTests: XCTestCase {
    @MainActor
    func testExplicitHotwordWeightAcceptsProtocolValuesOnly() {
        let metadata = AdaptiveTermMetadata(term: "Morrow", userWeight: 49)
        XCTAssertNil(metadata.userWeight)
        metadata.setUserWeight(50)
        XCTAssertEqual(metadata.userWeight, 50)
        metadata.setUserWeight(6)
        XCTAssertNil(metadata.userWeight)
        metadata.setUserWeight(5)
        XCTAssertEqual(metadata.userWeight, 5)
    }

    @MainActor
    func testSuccessfulSelectedTermRecordsOnlyLocalUsageSignals() throws {
        let schema = Schema([AdaptiveTermMetadata.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let metadata = AdaptiveTermMetadata(term: "Morrow")
        container.mainContext.insert(metadata)
        let timestamp = Date(timeIntervalSince1970: 2_000_000)
        let hints = RecognitionHintSnapshot(
            vocabulary: ["Morrow": 4, "Unused": 4],
            languageHints: ["zh"],
            context: nil,
            experimentArm: .dynamic,
            candidateCount: 2,
            contextKind: nil,
            sourceTypes: [],
            privacyDecision: "allowed",
            selectionTrace: RecognitionHintSelectionTrace(
                candidateCount: 2, selectedCount: 2, suppressedCount: 0),
            localAppBundleIdentifier: "com.example.editor",
            localURLHost: "docs.example",
            localModeIdentifier: "coding"
        )

        try AdaptiveTermUsageRecorder.recordSuccessfulUse(
            hints: hints,
            transcript: "继续完善 Morrow",
            in: container.mainContext,
            timestamp: timestamp
        )

        XCTAssertEqual(metadata.useCount, 1)
        XCTAssertEqual(metadata.lastUsedAt, timestamp)
        XCTAssertEqual(metadata.appIdentifiers, Set(["com.example.editor"]))
        XCTAssertEqual(metadata.hosts, Set(["docs.example"]))
        XCTAssertEqual(metadata.modes, Set(["coding"]))
    }

    func testLocalRecognitionSignalsDefaultOnAndCanBeDisabledIndependently() throws {
        let suite = "RecognitionHintTests.Signals.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(RecognitionContextSignalSettings.usesApp(defaults: defaults))
        XCTAssertTrue(RecognitionContextSignalSettings.usesURL(defaults: defaults))
        XCTAssertTrue(RecognitionContextSignalSettings.usesMode(defaults: defaults))

        defaults.set(false, forKey: RecognitionContextSignalSettings.useURLSignalKey)
        XCTAssertTrue(RecognitionContextSignalSettings.usesApp(defaults: defaults))
        XCTAssertFalse(RecognitionContextSignalSettings.usesURL(defaults: defaults))
        XCTAssertTrue(RecognitionContextSignalSettings.usesMode(defaults: defaults))
    }

    func testExperimentArmsAreDeterministicAndDoNotPad() {
        let candidates = ["Gamma", "Alpha", "Beta"].map {
            HotwordSelector.Candidate(term: $0, metadata: nil, isGlobalFallback: true)
        }
        let environment = RecognitionHintEnvironment(
            appBundleIdentifier: nil,
            urlHost: nil,
            modeIdentifier: nil,
            literalContext: nil
        )

        XCTAssertTrue(HotwordSelector.select(candidates: candidates, environment: environment, arm: .none).isEmpty)
        let all = HotwordSelector.select(candidates: candidates, environment: environment, arm: .all)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all, ["Alpha": 4, "Beta": 4, "Gamma": 4])

        let dynamic = HotwordSelector.select(
            candidates: candidates,
            environment: environment,
            arm: .dynamic,
            limit: 80
        )
        XCTAssertEqual(dynamic.count, 3, "A small personal dictionary must not be padded to Top 30")
    }

    func testDynamicSignalsAndNegativeFeedbackAffectRanking() {
        let relevant = signals(
            useCount: 10,
            correctionCount: 2,
            appIdentifiers: ["com.apple.textedit"],
            hosts: ["example.com"],
            modes: ["mode-a"]
        )
        let rejected = signals(negativeFeedbackCount: 20)
        let candidates = [
            HotwordSelector.Candidate(term: "Morrow", metadata: relevant),
            HotwordSelector.Candidate(term: "Rejected", metadata: rejected),
            HotwordSelector.Candidate(term: "LiteralHit", metadata: nil),
        ]
        let environment = RecognitionHintEnvironment(
            appBundleIdentifier: "com.apple.TextEdit",
            urlHost: "example.com",
            modeIdentifier: "mode-a",
            literalContext: "Please use LiteralHit and Morrow"
        )

        let result = HotwordSelector.select(
            candidates: candidates,
            environment: environment,
            arm: .dynamic,
            limit: 30,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(result["Morrow"], 4)
        XCTAssertEqual(result["LiteralHit"], 4)
        XCTAssertNil(result["Rejected"])
    }

    func testWeightFiveNeedsStrongFeedbackAndFiftyNeedsExplicitSetting() {
        let candidates = [
            HotwordSelector.Candidate(term: "Default", metadata: signals(), isGlobalFallback: true),
            HotwordSelector.Candidate(term: "Strong", metadata: signals(correctionCount: 3), isGlobalFallback: true),
            HotwordSelector.Candidate(term: "Explicit", metadata: signals(userWeight: 50), isGlobalFallback: true),
            HotwordSelector.Candidate(
                term: "Conflicted",
                metadata: signals(correctionCount: 8, negativeFeedbackCount: 1),
                isGlobalFallback: true
            ),
        ]
        let environment = RecognitionHintEnvironment(
            appBundleIdentifier: nil,
            urlHost: nil,
            modeIdentifier: nil,
            literalContext: nil
        )

        let result = HotwordSelector.select(candidates: candidates, environment: environment, arm: .dynamic)
        XCTAssertEqual(result["Default"], 4)
        XCTAssertEqual(result["Strong"], 5)
        XCTAssertEqual(result["Explicit"], 50)
        XCTAssertEqual(result["Conflicted"], 4)
    }

    func testPrivacyPolicyBlocksSecureControlsAndConfiguredDenials() throws {
        let suite = "RecognitionHintTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ContextPrivacyPolicy.areDenyListsEnabled(defaults: defaults))
        XCTAssertTrue(ContextPrivacyPolicy.decision(
            appBundleIdentifier: "com.example.app",
            urlHost: "safe.example",
            focusedControlIsSecure: false,
            defaults: defaults
        ).allowsContext)

        XCTAssertEqual(ContextPrivacyPolicy.decision(
            appBundleIdentifier: nil,
            urlHost: nil,
            focusedControlIsSecure: true,
            defaults: defaults
        ).reason, "secure-control")

        defaults.set(["com.example.app"], forKey: ContextPrivacyPolicy.deniedAppsDefaultsKey)
        XCTAssertEqual(ContextPrivacyPolicy.decision(
            appBundleIdentifier: "com.example.app",
            urlHost: nil,
            focusedControlIsSecure: false,
            defaults: defaults
        ).reason, "app-deny-list")

        defaults.set(["private.example"], forKey: ContextPrivacyPolicy.deniedHostsDefaultsKey)
        XCTAssertEqual(ContextPrivacyPolicy.decision(
            appBundleIdentifier: nil,
            urlHost: "mail.private.example",
            focusedControlIsSecure: false,
            defaults: defaults
        ).reason, "url-deny-list")

        defaults.set(false, forKey: ContextPrivacyPolicy.denyListsEnabledDefaultsKey)
        XCTAssertTrue(ContextPrivacyPolicy.decision(
            appBundleIdentifier: "com.example.app",
            urlHost: "mail.private.example",
            focusedControlIsSecure: false,
            defaults: defaults
        ).allowsContext)
        XCTAssertEqual(ContextPrivacyPolicy.decision(
            appBundleIdentifier: nil,
            urlHost: nil,
            focusedControlIsSecure: true,
            defaults: defaults
        ).reason, "secure-control")
    }

    func testLiteralContextIsBoundedAndContainsOnlyOriginalFragments() {
        let source = Array(repeating: "Morrow 专业术语 secret@example.com", count: 100).joined(separator: " ")
        let context = RecognitionLiteralContext.sanitize(source)
        XCTAssertNotNil(context)
        XCTAssertLessThanOrEqual(context?.count ?? .max, 400)
        XCTAssertTrue(context?.contains("Morrow") == true)
        XCTAssertTrue(context?.contains("专业术语") == true)
        XCTAssertFalse(context?.contains("@") == true)
    }

    func testUserFacingAuditSummaryContainsOnlySourceTypesAndCounts() {
        let snapshot = RecognitionHintSnapshot(
            vocabulary: ["SecretProject": 4, "PrivateName": 5],
            languageHints: ["zh"],
            context: "never show this raw context",
            experimentArm: .dynamic,
            candidateCount: 4,
            contextKind: "selected-text+clipboard",
            sourceTypes: ["selected-text", "clipboard"],
            privacyDecision: "allowed",
            selectionTrace: .init(candidateCount: 4, selectedCount: 2, suppressedCount: 2)
        )

        XCTAssertTrue(snapshot.userFacingAuditSummary.contains("2"))
        XCTAssertFalse(snapshot.userFacingAuditSummary.contains("SecretProject"))
        XCTAssertFalse(snapshot.userFacingAuditSummary.contains("PrivateName"))
        XCTAssertFalse(snapshot.userFacingAuditSummary.contains("never show"))
    }

    @MainActor
    func testAdaptiveMetadataSideTableDoesNotChangeVocabularyRows() throws {
        let schema = Schema([VocabularyWord.self, AdaptiveTermMetadata.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.insert(VocabularyWord(word: "Morrow"))
        context.insert(VocabularyWord(word: "morrow"))
        try context.save()

        let firstMigration = try AdaptiveTermMetadataMigration.run(in: context)
        let secondMigration = try AdaptiveTermMetadataMigration.run(in: context)

        let words = try context.fetch(FetchDescriptor<VocabularyWord>())
        let metadata = try context.fetch(FetchDescriptor<AdaptiveTermMetadata>())
        XCTAssertEqual(Set(words.map(\.word)), ["Morrow", "morrow"])
        XCTAssertEqual(firstMigration.createdCount, 1)
        XCTAssertEqual(firstMigration.duplicateNormalizedTermCount, 1)
        XCTAssertEqual(secondMigration.createdCount, 0)
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.first?.normalizedTerm, "morrow")
        XCTAssertEqual(metadata.first?.userWeight, nil)
        XCTAssertTrue(metadata.first?.isEnabled == true)
    }

    @MainActor
    func testExistingVocabularyStoreMigratesByAddingSideTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-term-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("dictionary.store")

        do {
            let oldSchema = Schema([VocabularyWord.self])
            let oldConfiguration = ModelConfiguration(
                "dictionary",
                schema: oldSchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let oldContainer = try ModelContainer(for: oldSchema, configurations: oldConfiguration)
            oldContainer.mainContext.insert(VocabularyWord(word: "ExistingTerm"))
            try oldContainer.mainContext.save()
        }

        let newSchema = Schema([VocabularyWord.self, AdaptiveTermMetadata.self])
        let newConfiguration = ModelConfiguration(
            "dictionary",
            schema: newSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let migratedContainer = try ModelContainer(for: newSchema, configurations: newConfiguration)
        let report = try AdaptiveTermMetadataMigration.run(in: migratedContainer.mainContext)
        let words = try migratedContainer.mainContext.fetch(FetchDescriptor<VocabularyWord>())
        let metadata = try migratedContainer.mainContext.fetch(FetchDescriptor<AdaptiveTermMetadata>())

        XCTAssertEqual(words.map(\.word), ["ExistingTerm"])
        XCTAssertEqual(report.createdCount, 1)
        XCTAssertEqual(metadata.map(\.normalizedTerm), ["existingterm"])
    }

    private func signals(
        isPinned: Bool = false,
        userWeight: Int? = nil,
        useCount: Int = 0,
        correctionCount: Int = 0,
        positiveFeedbackCount: Int = 0,
        negativeFeedbackCount: Int = 0,
        lastUsedAt: Date? = nil,
        appIdentifiers: Set<String> = [],
        hosts: Set<String> = [],
        modes: Set<String> = []
    ) -> HotwordSelector.AdaptiveTermSignals {
        .init(
            isPinned: isPinned,
            userWeight: userWeight,
            useCount: useCount,
            correctionCount: correctionCount,
            positiveFeedbackCount: positiveFeedbackCount,
            negativeFeedbackCount: negativeFeedbackCount,
            lastUsedAt: lastUsedAt,
            appIdentifiers: appIdentifiers,
            hosts: hosts,
            modes: modes
        )
    }
}
