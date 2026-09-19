import Foundation
import SwiftData

@ModelActor
actor WordReplacementStore {
    private enum MutationError: Error { case invalidReplacementSource }
    private enum NegativeFeedbackKind { case rejected, undone, reverted }
    func apply(
        _ decisions: [AutoLearnReviewDecision],
        candidates: [AutoLearnReviewCandidate]
    ) throws -> AutoLearnMutationSummary {
        guard !decisions.isEmpty else { return .empty }

        var createdCount = 0
        var updatedCount = 0
        var vocabularyCount = 0
        var learnedCorrections: [AutoLearnAppliedCorrection] = []

        do {
            try modelContext.transaction {
                var entries = try modelContext.fetch(FetchDescriptor<WordReplacement>())
                var existingSourceKeys = Set(
                    entries.flatMap {
                        WordReplacementVariants.parse($0.originalText).map {
                            WordReplacementVariants.key(for: $0)
                        }
                    }
                )
                var vocabularyKeys = Set(
                    try modelContext.fetch(FetchDescriptor<VocabularyWord>()).map {
                        WordReplacementVariants.key(for: $0.word)
                    }
                )
                let candidatesByID = Dictionary(
                    uniqueKeysWithValues: candidates.map { ($0.candidateID, $0) }
                )

                for decision in decisions {
                    guard let candidate = candidatesByID[decision.candidateID],
                        decision.learningAction != .rejectCorrection,
                        let correctedVocabularyTerm = decision.correctedVocabularyTerm
                    else { continue }

                    let mutation: (created: Bool, updated: Bool)
                    let shouldAddVocabulary: Bool
                    switch decision.learningAction {
                    case .addReplacementAndVocabulary:
                        shouldAddVocabulary = true
                        guard let incorrectTextToReplace = decision.incorrectTextToReplace else {
                            continue
                        }
                        mutation = try applyReplacement(
                            source: incorrectTextToReplace,
                            destination: correctedVocabularyTerm,
                            entries: &entries,
                            existingSourceKeys: &existingSourceKeys
                        )
                    case .addReplacementOnly:
                        shouldAddVocabulary = false
                        guard let incorrectTextToReplace = decision.incorrectTextToReplace else {
                            continue
                        }
                        mutation = try applyReplacement(
                            source: incorrectTextToReplace,
                            destination: correctedVocabularyTerm,
                            entries: &entries,
                            existingSourceKeys: &existingSourceKeys
                        )
                    case .addVocabularyOnly:
                        shouldAddVocabulary = true
                        mutation = (false, false)
                    case .rejectCorrection:
                        continue
                    }
                    createdCount += mutation.created ? 1 : 0
                    updatedCount += mutation.updated ? 1 : 0

                    let vocabulary = correctedVocabularyTerm
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .precomposedStringWithCanonicalMapping
                    let vocabularyKey = WordReplacementVariants.key(for: vocabulary)
                    var vocabularyCreationDate: Date?
                    if shouldAddVocabulary,
                        !vocabularyKey.isEmpty,
                        vocabularyKeys.insert(vocabularyKey).inserted
                    {
                        let entry = VocabularyWord(word: vocabulary)
                        modelContext.insert(entry)
                        vocabularyCreationDate = entry.dateAdded
                        vocabularyCount += 1
                    }

                    if mutation.created || mutation.updated || vocabularyCreationDate != nil {
                        if let source = decision.incorrectTextToReplace,
                            mutation.created || mutation.updated
                        {
                            recordAcceptedFeedback(
                                source: source,
                                destination: correctedVocabularyTerm
                            )
                        } else if vocabularyCreationDate != nil {
                            recordAcceptedVocabulary(term: correctedVocabularyTerm)
                        }
                        learnedCorrections.append(
                            AutoLearnAppliedCorrection(
                                incorrectTextToReplace: decision.incorrectTextToReplace
                                    ?? candidate.originalText,
                                correctedVocabularyTerm: correctedVocabularyTerm,
                                replacementSourceWasAdded: mutation.created || mutation.updated,
                                vocabularyCreationDate: vocabularyCreationDate
                            )
                        )
                    }
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        return AutoLearnMutationSummary(
            createdCount: createdCount,
            updatedCount: updatedCount,
            vocabularyCount: vocabularyCount,
            learnedCorrections: learnedCorrections
        )
    }

    func undo(_ correction: AutoLearnAppliedCorrection) throws {
        try modelContext.transaction {
            if correction.replacementSourceWasAdded {
                recordNegativeFeedback(
                    source: correction.incorrectTextToReplace,
                    destination: correction.correctedVocabularyTerm,
                    kind: .undone
                )
            } else {
                recordAdaptiveNegative(term: correction.correctedVocabularyTerm)
            }
            if correction.replacementSourceWasAdded {
                let destinationKey = WordReplacementVariants.destinationKey(
                    for: correction.correctedVocabularyTerm
                )
                let entries = try modelContext.fetch(FetchDescriptor<WordReplacement>())
                if let entry = entries.first(where: {
                    WordReplacementVariants.destinationKey(for: $0.replacementText) == destinationKey
                        && WordReplacementVariants.contains(
                            correction.incorrectTextToReplace,
                            in: WordReplacementVariants.parse($0.originalText)
                        )
                }) {
                    var variants = WordReplacementVariants.parse(entry.originalText)
                    variants.removeAll {
                        WordReplacementVariants.key(for: $0)
                            == WordReplacementVariants.key(
                                for: correction.incorrectTextToReplace
                            )
                    }
                    if variants.isEmpty {
                        modelContext.delete(entry)
                    } else {
                        entry.originalText = WordReplacementVariants.serialize(variants)
                    }
                }
            }

            if let creationDate = correction.vocabularyCreationDate {
                let vocabularyKey = WordReplacementVariants.key(
                    for: correction.correctedVocabularyTerm
                )
                let vocabulary = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
                if let entry = vocabulary.first(where: {
                    $0.dateAdded == creationDate
                        && WordReplacementVariants.key(for: $0.word) == vocabularyKey
                }) {
                    modelContext.delete(entry)
                }
            }
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func recordRejected(_ proposals: [AutoLearnReviewProposal]) throws {
        guard !proposals.isEmpty else { return }
        try modelContext.transaction {
            for proposal in proposals {
                guard let destination = proposal.correctedVocabularyTerm else { continue }
                if proposal.addsReplacement, let source = proposal.incorrectTextToReplace {
                    recordNegativeFeedback(
                        source: source,
                        destination: destination,
                        kind: .rejected
                    )
                } else {
                    recordAdaptiveNegative(term: destination)
                }
            }
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Detects the strongest possible "changed it back" signal: replacing a
    /// learned destination with its exact source must reproduce the whole
    /// observed revision. Ambiguous or partial rewrites are ignored.
    func recordUserReverts(in revision: AutoLearnRevision) throws -> Int {
        let rules = try modelContext.fetch(FetchDescriptor<WordReplacement>())
        let existingFeedback = try modelContext.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())
        let feedbackByKey = Dictionary(
            existingFeedback.map { ($0.ruleKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var matches: [(source: String, destination: String)] = []

        for rule in rules where rule.isEnabled {
            for source in WordReplacementVariants.parse(rule.originalText) {
                let key = CorrectionFeedbackMetadata.key(
                    originalTerm: source,
                    replacementTerm: rule.replacementText
                )
                guard feedbackByKey[key]?.isEnabled != false else { continue }
                let reverted = revision.original.replacingOccurrences(
                    of: rule.replacementText,
                    with: source,
                    options: .caseInsensitive
                )
                guard reverted != revision.original,
                    AutoLearnTextNormalizer.accessibilityComparable(reverted)
                        == AutoLearnTextNormalizer.accessibilityComparable(revision.corrected)
                else { continue }
                matches.append((source, rule.replacementText))
            }
        }

        guard !matches.isEmpty else { return 0 }
        do {
            try modelContext.transaction {
                for match in matches {
                    recordNegativeFeedback(
                        source: match.source,
                        destination: match.destination,
                        kind: .reverted
                    )
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return matches.count
    }

    private func applyReplacement(
        source rawSource: String,
        destination rawDestination: String,
        entries: inout [WordReplacement],
        existingSourceKeys: inout Set<String>
    ) throws -> (created: Bool, updated: Bool) {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let sourceKey = WordReplacementVariants.key(for: source)
        let destinationKey = WordReplacementVariants.destinationKey(for: destination)
        let destinationSourceKey = WordReplacementVariants.key(for: destination)

        guard !source.contains(",") else { throw MutationError.invalidReplacementSource }
        guard !source.isEmpty, !destination.isEmpty,
            !sourceKey.isEmpty, !destinationKey.isEmpty,
            source != destination,
            !existingSourceKeys.contains(sourceKey),
            !wouldCreateCycle(
                sourceKey: sourceKey,
                destinationSourceKey: destinationSourceKey,
                entries: entries
            )
        else {
            return (false, false)
        }

        let destinationMatches = entries
            .filter {
                WordReplacementVariants.destinationKey(for: $0.replacementText) == destinationKey
            }
            .sorted(by: destinationOrder)
        let canonical = destinationMatches.first

        if let canonical {
            // Auto Learn only adds the learned source without rewriting rows,
            // allowing Undo to remove exactly what was added.
            var variants = WordReplacementVariants.parse(canonical.originalText)
            variants.append(source)
            canonical.originalText = WordReplacementVariants.serialize(variants)
        } else {
            let entry = WordReplacement(
                originalText: WordReplacementVariants.serialize([source]),
                replacementText: destination
            )
            modelContext.insert(entry)
            entries.append(entry)
        }

        existingSourceKeys.insert(sourceKey)
        return (canonical == nil, canonical != nil)
    }

    private func recordAcceptedFeedback(source: String, destination: String) {
        let metadata = feedbackMetadata(source: source, destination: destination)
        metadata.acceptedCount += 1
        metadata.confidence = min(1, metadata.confidence + 0.15)
        metadata.isEnabled = true
        metadata.lastTriggeredAt = Date()

        let adaptive = adaptiveMetadata(term: destination)
        adaptive.correctionCount += 1
        adaptive.positiveFeedbackCount += 1
        adaptive.lastUsedAt = Date()
    }

    private func recordAcceptedVocabulary(term: String) {
        let adaptive = adaptiveMetadata(term: term)
        adaptive.positiveFeedbackCount += 1
        adaptive.lastUsedAt = Date()
    }

    private func recordNegativeFeedback(
        source: String,
        destination: String,
        kind: NegativeFeedbackKind
    ) {
        let metadata = feedbackMetadata(source: source, destination: destination)
        switch kind {
        case .rejected: metadata.rejectedCount += 1
        case .undone: metadata.undoCount += 1
        case .reverted: metadata.revertCount += 1
        }
        metadata.confidence = max(0, metadata.confidence - 0.25)
        if metadata.negativeFeedbackCount >= 2 || metadata.confidence <= 0.05 {
            metadata.isEnabled = false
        }
        metadata.lastTriggeredAt = Date()

        recordAdaptiveNegative(term: destination)
    }

    private func recordAdaptiveNegative(term: String) {
        let adaptive = adaptiveMetadata(term: term)
        adaptive.negativeFeedbackCount += 1
        adaptive.lastUsedAt = Date()
    }

    private func feedbackMetadata(
        source: String,
        destination: String
    ) -> CorrectionFeedbackMetadata {
        let key = CorrectionFeedbackMetadata.key(
            originalTerm: source,
            replacementTerm: destination
        )
        let existing = (try? modelContext.fetch(FetchDescriptor<CorrectionFeedbackMetadata>())) ?? []
        if let metadata = existing.first(where: { $0.ruleKey == key }) {
            return metadata
        }
        let metadata = CorrectionFeedbackMetadata(
            originalTerm: source,
            replacementTerm: destination
        )
        modelContext.insert(metadata)
        return metadata
    }

    private func adaptiveMetadata(term: String) -> AdaptiveTermMetadata {
        let key = AdaptiveTermMetadata.normalize(term)
        let existing = (try? modelContext.fetch(FetchDescriptor<AdaptiveTermMetadata>())) ?? []
        if let metadata = existing.first(where: { $0.normalizedTerm == key }) {
            return metadata
        }
        let metadata = AdaptiveTermMetadata(term: term)
        modelContext.insert(metadata)
        return metadata
    }

    private func destinationOrder(_ lhs: WordReplacement, _ rhs: WordReplacement) -> Bool {
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded < rhs.dateAdded
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func wouldCreateCycle(
        sourceKey: String,
        destinationSourceKey: String,
        entries: [WordReplacement]
    ) -> Bool {
        WordReplacementVariants.wouldCreateCycle(
            newSources: [(source: sourceKey, destination: destinationSourceKey)],
            in: entries
                .sorted(by: destinationOrder)
                .map { (originalText: $0.originalText, replacementText: $0.replacementText) }
        )
    }
}
