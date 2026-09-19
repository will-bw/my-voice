import ApplicationServices
import AppKit
import Foundation
import SwiftData

enum HotwordExperimentArm: String, CaseIterable, Sendable {
    case none
    case all
    case dynamic

    static let defaultsKey = "HotwordExperimentArm"

    static var current: HotwordExperimentArm {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = HotwordExperimentArm(rawValue: raw)
        else {
            return .dynamic
        }
        return value
    }
}

/// An immutable, request-scoped set of recognition hints. The same value is
/// passed to streaming and every batch retry for one recording.
struct RecognitionHintSnapshot: Equatable, Sendable {
    let vocabulary: [String: Int]
    let languageHints: [String]
    let context: String?
    let experimentArm: HotwordExperimentArm
    let candidateCount: Int
    let contextKind: String?
    let sourceTypes: [String]
    let privacyDecision: String
    let selectionTrace: RecognitionHintSelectionTrace

    /// Ephemeral UI audit text. It deliberately contains only source categories and counts.
    var userFacingAuditSummary: String {
        let contextDescription: String
        if privacyDecision != "allowed" {
            contextDescription = String(localized: "Context blocked")
        } else if sourceTypes.isEmpty {
            contextDescription = String(localized: "Context: none")
        } else {
            let labels = sourceTypes.map(Self.userFacingSourceLabel).joined(separator: ", ")
            contextDescription = String(localized: "Context: \(labels)")
        }
        return "\(contextDescription) · \(vocabulary.count) " + String(localized: "hotwords")
    }

    private static func userFacingSourceLabel(_ source: String) -> String {
        switch source {
        case "selected-text": String(localized: "selection")
        case "clipboard": String(localized: "clipboard")
        case "screen-text": String(localized: "screen text")
        default: source
        }
    }

    static func empty(language: String? = nil, arm: HotwordExperimentArm = .none) -> RecognitionHintSnapshot {
        RecognitionHintSnapshot(
            vocabulary: [:],
            languageHints: Self.languages(from: language),
            context: nil,
            experimentArm: arm,
            candidateCount: 0,
            contextKind: nil,
            sourceTypes: [],
            privacyDecision: "allowed",
            selectionTrace: RecognitionHintSelectionTrace(candidateCount: 0, selectedCount: 0, suppressedCount: 0)
        )
    }

    static func languages(from language: String?) -> [String] {
        guard let language, !language.isEmpty, language != "auto" else { return [] }
        return [language]
    }
}

struct RecognitionHintSelectionTrace: Equatable, Sendable {
    let candidateCount: Int
    let selectedCount: Int
    let suppressedCount: Int
}

struct RecognitionHintEnvironment: Equatable, Sendable {
    let appBundleIdentifier: String?
    let urlHost: String?
    let modeIdentifier: String?
    let literalContext: String?
}

struct ContextPrivacyDecision: Equatable, Sendable {
    let allowsContext: Bool
    let reason: String?
}

enum ContextPrivacyPolicy {
    static let deniedAppsDefaultsKey = "RecognitionContextDeniedApps"
    static let deniedHostsDefaultsKey = "RecognitionContextDeniedHosts"

    static func decision(
        appBundleIdentifier: String?,
        urlHost: String?,
        focusedControlIsSecure: Bool,
        defaults: UserDefaults = .standard
    ) -> ContextPrivacyDecision {
        decision(
            appBundleIdentifier: appBundleIdentifier,
            urlHost: urlHost,
            focusedControlSecurity: focusedControlIsSecure,
            defaults: defaults
        )
    }

    private static func decision(
        appBundleIdentifier: String?,
        urlHost: String?,
        focusedControlSecurity: Bool?,
        defaults: UserDefaults
    ) -> ContextPrivacyDecision {
        guard let focusedControlSecurity else {
            return ContextPrivacyDecision(allowsContext: false, reason: "security-boundary-unavailable")
        }
        if focusedControlSecurity {
            return ContextPrivacyDecision(allowsContext: false, reason: "secure-control")
        }

        let deniedApps = Set(defaults.stringArray(forKey: deniedAppsDefaultsKey) ?? [])
        if let appBundleIdentifier,
            deniedApps.contains(where: { $0.caseInsensitiveCompare(appBundleIdentifier) == .orderedSame })
        {
            return ContextPrivacyDecision(allowsContext: false, reason: "app-deny-list")
        }

        let deniedHosts = (defaults.stringArray(forKey: deniedHostsDefaultsKey) ?? []).map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        if let host = urlHost?.lowercased(),
            deniedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        {
            return ContextPrivacyDecision(allowsContext: false, reason: "url-deny-list")
        }

        return ContextPrivacyDecision(allowsContext: true, reason: nil)
    }

    @MainActor
    static func currentDecision(appBundleIdentifier: String?, urlHost: String?) -> ContextPrivacyDecision {
        decision(
            appBundleIdentifier: appBundleIdentifier,
            urlHost: urlHost,
            focusedControlSecurity: FocusedControlSecurityInspector.secureInputStatus(),
            defaults: .standard
        )
    }
}

private enum FocusedControlSecurityInspector {
    /// `nil` means the safety boundary could not be verified and content must
    /// not be captured.
    static func secureInputStatus() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        if attribute(kAXSubroleAttribute, from: element) == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        return attribute(kAXRoleAttribute, from: element) == nil ? nil : false
    }

    private static func attribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

enum RecognitionLiteralContext {
    /// Keeps only short, unique literal fragments from an allowed source. The
    /// original source text is not retained and output stays below the API cap.
    static func sanitize(_ text: String?, maximumCharacters: Int = 400) -> String? {
        guard let text else { return nil }
        let pattern = #"[\p{L}\p{N}_+.#/-]{2,40}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var fragments: [String] = []
        var length = 0

        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let fragment = String(text[swiftRange])
            let key = AdaptiveTermMetadata.normalize(fragment)
            guard seen.insert(key).inserted else { continue }
            let addedLength = fragment.count + (fragments.isEmpty ? 0 : 1)
            guard length + addedLength <= maximumCharacters else { break }
            fragments.append(fragment)
            length += addedLength
            if fragments.count == 40 { break }
        }

        return fragments.isEmpty ? nil : fragments.joined(separator: " ")
    }

    static func combine(_ fragments: [(source: String, text: String?)], maximumCharacters: Int = 400)
        -> (text: String?, sources: [String])
    {
        var result = ""
        var sources: [String] = []
        for fragment in fragments {
            guard let sanitized = sanitize(fragment.text, maximumCharacters: maximumCharacters), !sanitized.isEmpty else {
                continue
            }
            let separator = result.isEmpty ? "" : " "
            let remaining = maximumCharacters - result.count - separator.count
            guard remaining > 0 else { break }
            result += separator + String(sanitized.prefix(remaining))
            sources.append(fragment.source)
        }
        return (result.isEmpty ? nil : result, sources)
    }
}

enum HotwordSelector {
    struct Candidate: Equatable, Sendable {
        let term: String
        let metadata: AdaptiveTermSignals?
        let isGlobalFallback: Bool

        init(term: String, metadata: AdaptiveTermSignals?, isGlobalFallback: Bool = false) {
            self.term = term
            self.metadata = metadata
            self.isGlobalFallback = isGlobalFallback
        }
    }

    struct AdaptiveTermSignals: Equatable, Sendable {
        let isPinned: Bool
        let userWeight: Int?
        let useCount: Int
        let correctionCount: Int
        let positiveFeedbackCount: Int
        let negativeFeedbackCount: Int
        let lastUsedAt: Date?
        let appIdentifiers: Set<String>
        let hosts: Set<String>
        let modes: Set<String>
        let isEnabled: Bool

        init(
            isPinned: Bool,
            userWeight: Int?,
            useCount: Int,
            correctionCount: Int,
            positiveFeedbackCount: Int,
            negativeFeedbackCount: Int,
            lastUsedAt: Date?,
            appIdentifiers: Set<String>,
            hosts: Set<String>,
            modes: Set<String>,
            isEnabled: Bool = true
        ) {
            self.isPinned = isPinned
            self.userWeight = userWeight
            self.useCount = useCount
            self.correctionCount = correctionCount
            self.positiveFeedbackCount = positiveFeedbackCount
            self.negativeFeedbackCount = negativeFeedbackCount
            self.lastUsedAt = lastUsedAt
            self.appIdentifiers = appIdentifiers
            self.hosts = hosts
            self.modes = modes
            self.isEnabled = isEnabled
        }

        init(_ metadata: AdaptiveTermMetadata) {
            isPinned = metadata.isPinned
            userWeight = metadata.userWeight
            useCount = metadata.useCount
            correctionCount = metadata.correctionCount
            positiveFeedbackCount = metadata.positiveFeedbackCount
            negativeFeedbackCount = metadata.negativeFeedbackCount
            lastUsedAt = metadata.lastUsedAt
            appIdentifiers = metadata.appIdentifiers
            hosts = metadata.hosts
            modes = metadata.modes
            isEnabled = metadata.isEnabled
        }
    }

    static func select(
        candidates: [Candidate],
        environment: RecognitionHintEnvironment,
        arm: HotwordExperimentArm,
        limit requestedLimit: Int = 50,
        now: Date = Date()
    ) -> [String: Int] {
        guard arm != .none else { return [:] }
        let limit = arm == .all ? 2_000 : min(80, max(30, requestedLimit))
        let context = AdaptiveTermMetadata.normalize(environment.literalContext ?? "")

        let unique = Dictionary(grouping: candidates, by: { AdaptiveTermMetadata.normalize($0.term) })
            .compactMap { key, values -> Candidate? in
                guard !key.isEmpty else { return nil }
                return values.max { score($0, environment: environment, context: context, now: now) < score($1, environment: environment, context: context, now: now) }
            }

        let ranked: [Candidate]
        if arm == .all {
            ranked = unique.sorted { lhs, rhs in
                AdaptiveTermMetadata.normalize(lhs.term) < AdaptiveTermMetadata.normalize(rhs.term)
            }
        } else {
            ranked = unique
                .filter { $0.metadata?.isEnabled != false }
                .map { ($0, score($0, environment: environment, context: context, now: now)) }
                .filter { candidate, score in
                    score > 0 || candidate.metadata?.isPinned == true || candidate.metadata?.userWeight != nil
                }
                .sorted {
                    if $0.1 == $1.1 {
                        return AdaptiveTermMetadata.normalize($0.0.term) < AdaptiveTermMetadata.normalize($1.0.term)
                    }
                    return $0.1 > $1.1
                }
                .map(\.0)
        }

        var result: [String: Int] = [:]
        for candidate in ranked.prefix(limit) {
            result[candidate.term] = weight(for: candidate.metadata)
        }
        return result
    }

    private static func score(
        _ candidate: Candidate,
        environment: RecognitionHintEnvironment,
        context: String,
        now: Date
    ) -> Double {
        let normalized = AdaptiveTermMetadata.normalize(candidate.term)
        let metadata = candidate.metadata
        // Only a small deterministic slice of the personal dictionary receives
        // a global fallback signal. Unrelated low-quality terms are not padding.
        var value = candidate.isGlobalFallback ? 1.0 : 0.0
        if metadata?.isPinned == true { value += 100 }
        if !context.isEmpty, context.range(of: normalized) != nil { value += 40 }
        if let app = environment.appBundleIdentifier?.lowercased(), metadata?.appIdentifiers.contains(app) == true {
            value += 30
        }
        if let host = environment.urlHost?.lowercased(), metadata?.hosts.contains(host) == true { value += 25 }
        if let mode = environment.modeIdentifier?.lowercased(), metadata?.modes.contains(mode) == true { value += 25 }
        value += min(10, log2(Double((metadata?.useCount ?? 0) + 1)) * 2)
        if (metadata?.correctionCount ?? 0) > 0 { value += 20 }
        value += Double(metadata?.positiveFeedbackCount ?? 0) * 3
        value -= Double(metadata?.negativeFeedbackCount ?? 0) * 20
        if let lastUsedAt = metadata?.lastUsedAt {
            let days = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
            value += max(-10, 15 - days / 2)
        }
        return value
    }

    private static func weight(for metadata: AdaptiveTermSignals?) -> Int {
        if metadata?.userWeight == 50 { return 50 }
        if let userWeight = metadata?.userWeight, (1...5).contains(userWeight) { return userWeight }
        let strongFeedback = (metadata?.correctionCount ?? 0) >= 3
            || (metadata?.positiveFeedbackCount ?? 0) >= 5
        return strongFeedback && (metadata?.negativeFeedbackCount ?? 0) == 0 ? 5 : 4
    }
}

@MainActor
enum RecognitionHintSnapshotBuilder {
    static func capture(
        modelContext: ModelContext,
        mode: ModeConfig,
        language: String?,
        experimentArm: HotwordExperimentArm = .current,
        limit: Int = 50
    ) async -> RecognitionHintSnapshot {
        let appIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let urlHost = ActiveWindowService.shared.currentURL?.host
        let privacy = ContextPrivacyPolicy.currentDecision(
            appBundleIdentifier: appIdentifier,
            urlHost: urlHost
        )
        guard privacy.allowsContext else {
            return make(
                modelContext: modelContext,
                mode: mode,
                language: language,
                literalContext: nil,
                sourceTypes: [],
                privacyDecision: privacy.reason ?? "blocked",
                appBundleIdentifier: appIdentifier,
                urlHost: urlHost,
                experimentArm: experimentArm,
                limit: limit
            )
        }

        async let selectedText = mode.useSelectedTextContext ? SelectedTextService.fetchSelectedText() : nil
        async let screenText: String? = {
            guard mode.useScreenCapture, CGPreflightScreenCaptureAccess() else { return nil }
            return await ScreenCaptureService().captureAndExtractText()
        }()
        let clipboardText = mode.useClipboardContext ? NSPasteboard.general.string(forType: .string) : nil
        let combined = await RecognitionLiteralContext.combine([
            ("selected-text", selectedText),
            ("clipboard", clipboardText),
            ("screen-text", screenText),
        ])
        return make(
            modelContext: modelContext,
            mode: mode,
            language: language,
            literalContext: combined.text,
            sourceTypes: combined.sources,
            privacyDecision: "allowed",
            appBundleIdentifier: appIdentifier,
            urlHost: urlHost,
            experimentArm: experimentArm,
            limit: limit
        )
    }

    static func make(
        modelContext: ModelContext,
        mode: ModeConfig,
        language: String?,
        selectedText: String?,
        experimentArm: HotwordExperimentArm = .current,
        limit: Int = 50
    ) -> RecognitionHintSnapshot {
        make(
            modelContext: modelContext,
            mode: mode,
            language: language,
            literalContext: RecognitionLiteralContext.sanitize(selectedText),
            sourceTypes: selectedText == nil ? [] : ["selected-text"],
            privacyDecision: "allowed",
            appBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            urlHost: ActiveWindowService.shared.currentURL?.host,
            experimentArm: experimentArm,
            limit: limit
        )
    }

    private static func make(
        modelContext: ModelContext,
        mode: ModeConfig,
        language: String?,
        literalContext: String?,
        sourceTypes: [String],
        privacyDecision: String,
        appBundleIdentifier: String?,
        urlHost: String?,
        experimentArm: HotwordExperimentArm,
        limit: Int
    ) -> RecognitionHintSnapshot {
        let words = (try? modelContext.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let metadata = (try? modelContext.fetch(FetchDescriptor<AdaptiveTermMetadata>())) ?? []
        let metadataByTerm = Dictionary(
            metadata.map { ($0.normalizedTerm, HotwordSelector.AdaptiveTermSignals($0)) },
            uniquingKeysWith: { lhs, rhs in lhs.positiveFeedbackCount >= rhs.positiveFeedbackCount ? lhs : rhs }
        )

        var seen = Set<String>()
        var candidates: [HotwordSelector.Candidate] = []
        let fallbackKeys = Set(
            words.sorted { $0.dateAdded > $1.dateAdded }.prefix(20).map {
                AdaptiveTermMetadata.normalize($0.word)
            }
        )
        for word in words.map(\.word) + mode.triggerWords {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = AdaptiveTermMetadata.normalize(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let stored = metadataByTerm[key]
            let signals: HotwordSelector.AdaptiveTermSignals?
            if mode.triggerWords.contains(where: { AdaptiveTermMetadata.normalize($0) == key }), stored == nil {
                signals = .init(
                    isPinned: true,
                    userWeight: nil,
                    useCount: 0,
                    correctionCount: 0,
                    positiveFeedbackCount: 0,
                    negativeFeedbackCount: 0,
                    lastUsedAt: nil,
                    appIdentifiers: [],
                    hosts: [],
                    modes: [],
                    isEnabled: true
                )
            } else {
                signals = stored
            }
            candidates.append(.init(term: trimmed, metadata: signals, isGlobalFallback: fallbackKeys.contains(key)))
        }

        let environment = RecognitionHintEnvironment(
            appBundleIdentifier: appBundleIdentifier,
            urlHost: urlHost,
            modeIdentifier: mode.id.uuidString.lowercased(),
            literalContext: literalContext
        )
        let vocabulary = HotwordSelector.select(
            candidates: candidates,
            environment: environment,
            arm: experimentArm,
            limit: limit
        )
        return RecognitionHintSnapshot(
            vocabulary: vocabulary,
            languageHints: RecognitionHintSnapshot.languages(from: language),
            context: literalContext,
            experimentArm: experimentArm,
            candidateCount: candidates.count,
            contextKind: sourceTypes.isEmpty ? nil : sourceTypes.joined(separator: "+"),
            sourceTypes: sourceTypes,
            privacyDecision: privacyDecision,
            selectionTrace: RecognitionHintSelectionTrace(
                candidateCount: candidates.count,
                selectedCount: vocabulary.count,
                suppressedCount: max(0, candidates.count - vocabulary.count)
            )
        )
    }
}
