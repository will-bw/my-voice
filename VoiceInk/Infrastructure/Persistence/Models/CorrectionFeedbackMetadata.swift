import Foundation
import SwiftData

/// Local-only feedback for one exact replacement source/destination pair.
///
/// Keeping this separate from `WordReplacement` preserves upstream dictionary
/// compatibility while allowing individual variants in a comma-separated rule
/// to be disabled after repeated negative feedback.
@Model
final class CorrectionFeedbackMetadata {
    @Attribute(.unique) var ruleKey: String = ""
    var originalTerm: String = ""
    var replacementTerm: String = ""
    var schemaVersion: Int = 1
    var acceptedCount: Int = 0
    var rejectedCount: Int = 0
    var undoCount: Int = 0
    var revertCount: Int = 0
    var confidence: Double = 0.5
    var isEnabled: Bool = true
    var lastTriggeredAt: Date?

    init(originalTerm: String, replacementTerm: String) {
        let original = Self.canonical(originalTerm)
        let replacement = Self.canonical(replacementTerm)
        self.ruleKey = Self.key(originalTerm: original, replacementTerm: replacement)
        self.originalTerm = original
        self.replacementTerm = replacement
    }

    var negativeFeedbackCount: Int {
        rejectedCount + undoCount + revertCount
    }

    static func key(originalTerm: String, replacementTerm: String) -> String {
        let original = normalize(originalTerm)
        let replacement = normalize(replacementTerm)
        return "\(original.utf8.count):\(original)\(replacement.utf8.count):\(replacement)"
    }

    static func normalize(_ value: String) -> String {
        canonical(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func canonical(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

struct CorrectionFeedbackMigrationReport: Equatable, Sendable {
    let createdCount: Int
    let duplicateRuleCount: Int
    let orphanMetadataCount: Int
}

@MainActor
enum CorrectionFeedbackMetadataMigration {
    static func run(in context: ModelContext) throws -> CorrectionFeedbackMigrationReport {
        let rules = try context.fetch(FetchDescriptor<WordReplacement>())
        let existing = try context.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())
        var existingKeys = Set(existing.map(\.ruleKey).filter { !$0.isEmpty })
        var seenRuleKeys = Set<String>()
        var duplicateCount = 0
        var createdCount = 0

        for rule in rules {
            for source in WordReplacementVariants.parse(rule.originalText) {
                let key = CorrectionFeedbackMetadata.key(
                    originalTerm: source,
                    replacementTerm: rule.replacementText
                )
                guard !key.isEmpty else { continue }
                if !seenRuleKeys.insert(key).inserted {
                    duplicateCount += 1
                    continue
                }
                guard !existingKeys.contains(key) else { continue }
                context.insert(
                    CorrectionFeedbackMetadata(
                        originalTerm: source,
                        replacementTerm: rule.replacementText
                    )
                )
                existingKeys.insert(key)
                createdCount += 1
            }
        }

        if createdCount > 0 { try context.save() }
        let orphanCount = existingKeys.subtracting(seenRuleKeys).count
        return CorrectionFeedbackMigrationReport(
            createdCount: createdCount,
            duplicateRuleCount: duplicateCount,
            orphanMetadataCount: orphanCount
        )
    }
}
