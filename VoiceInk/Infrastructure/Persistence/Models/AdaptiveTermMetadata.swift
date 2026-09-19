import Foundation
import SwiftData

/// Local-only scoring signals associated with a vocabulary term.
///
/// This is deliberately a side table: the existing `VocabularyWord` schema stays
/// unchanged, so adding adaptive ranking cannot corrupt or rewrite the user's
/// personal dictionary.
@Model
final class AdaptiveTermMetadata {
    @Attribute(.unique) var normalizedTerm: String = ""
    var displayTerm: String = ""
    var schemaVersion: Int = 1
    var language: String?
    var isEnabled: Bool = true
    var isPinned: Bool = false
    var userWeight: Int?
    var useCount: Int = 0
    var correctionCount: Int = 0
    var positiveFeedbackCount: Int = 0
    var negativeFeedbackCount: Int = 0
    var lastUsedAt: Date?
    var appBundleIdentifiers: String = ""
    var urlHosts: String = ""
    var modeIdentifiers: String = ""

    init(
        term: String,
        language: String? = nil,
        isEnabled: Bool = true,
        isPinned: Bool = false,
        userWeight: Int? = nil,
        useCount: Int = 0,
        correctionCount: Int = 0,
        positiveFeedbackCount: Int = 0,
        negativeFeedbackCount: Int = 0,
        lastUsedAt: Date? = nil,
        appBundleIdentifiers: Set<String> = [],
        urlHosts: Set<String> = [],
        modeIdentifiers: Set<String> = []
    ) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedTerm = Self.normalize(trimmed)
        self.displayTerm = trimmed
        self.schemaVersion = 1
        self.language = language
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.userWeight = userWeight
        self.useCount = max(0, useCount)
        self.correctionCount = max(0, correctionCount)
        self.positiveFeedbackCount = max(0, positiveFeedbackCount)
        self.negativeFeedbackCount = max(0, negativeFeedbackCount)
        self.lastUsedAt = lastUsedAt
        self.appBundleIdentifiers = Self.encode(appBundleIdentifiers)
        self.urlHosts = Self.encode(urlHosts)
        self.modeIdentifiers = Self.encode(modeIdentifiers)
    }

    var appIdentifiers: Set<String> { Self.decode(appBundleIdentifiers) }
    var hosts: Set<String> { Self.decode(urlHosts) }
    var modes: Set<String> { Self.decode(modeIdentifiers) }

    static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func encode(_ values: Set<String>) -> String {
        values.map { $0.lowercased() }.sorted().joined(separator: "\n")
    }

    private static func decode(_ value: String) -> Set<String> {
        Set(value.split(separator: "\n").map { String($0).lowercased() })
    }
}

struct AdaptiveTermMigrationReport: Equatable, Sendable {
    let createdCount: Int
    let duplicateNormalizedTermCount: Int
    let orphanMetadataCount: Int
}

@MainActor
enum AdaptiveTermMetadataMigration {
    /// Idempotently creates one metadata row per normalized vocabulary key.
    /// Duplicate visible dictionary rows are preserved and only reported.
    static func run(in context: ModelContext) throws -> AdaptiveTermMigrationReport {
        let words = try context.fetch(FetchDescriptor<VocabularyWord>())
        let existing = try context.fetch(FetchDescriptor<AdaptiveTermMetadata>())
        var existingKeys = Set(existing.map(\.normalizedTerm).filter { !$0.isEmpty })
        let wordGroups = Dictionary(grouping: words) { normalize($0.word) }
        var createdCount = 0

        for (key, group) in wordGroups where !key.isEmpty && !existingKeys.contains(key) {
            guard let displayWord = group.first?.word else { continue }
            context.insert(AdaptiveTermMetadata(term: displayWord))
            existingKeys.insert(key)
            createdCount += 1
        }

        if createdCount > 0 { try context.save() }
        let duplicateCount = wordGroups.values.reduce(0) { $0 + max(0, $1.count - 1) }
        let vocabularyKeys = Set(wordGroups.keys.filter { !$0.isEmpty })
        let orphanCount = existingKeys.subtracting(vocabularyKeys).count
        return AdaptiveTermMigrationReport(
            createdCount: createdCount,
            duplicateNormalizedTermCount: duplicateCount,
            orphanMetadataCount: orphanCount
        )
    }

    private static func normalize(_ term: String) -> String {
        AdaptiveTermMetadata.normalize(term)
    }
}
