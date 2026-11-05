import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let isAudioHistoryEnabled = "IsAudioHistoryEnabled"
    static let audioHistoryDirectory = "AudioHistoryDirectory"
    static let audioHistoryMaximumBytes = "AudioHistoryMaximumBytes"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum AudioHistorySettings {
    static let defaultRetentionDays = 7
    static let defaultMaximumBytes: Int64 = 1_073_741_824

    static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: CleanupSettingsKeys.isAudioHistoryEnabled)
    }

    static var retentionDays: Int {
        max(1, UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod))
    }

    static var maximumBytes: Int64 {
        let stored = UserDefaults.standard.object(forKey: CleanupSettingsKeys.audioHistoryMaximumBytes) as? NSNumber
        return max(1, stored?.int64Value ?? defaultMaximumBytes)
    }

    static var recordingsDirectory: URL {
        guard isEnabled else { return temporaryRecordingsDirectory }
        if let path = UserDefaults.standard.string(forKey: CleanupSettingsKeys.audioHistoryDirectory),
            !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultRecordingsDirectory
    }

    static var temporaryRecordingsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(AppIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("SessionRecordings", isDirectory: true)
    }

    static var defaultRecordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func removeStaleTemporaryRecordings(
        fileManager: FileManager = .default,
        directory: URL? = nil
    ) -> (removedCount: Int, errorCount: Int) {
        let directory = directory ?? temporaryRecordingsDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var removedCount = 0
        var errorCount = 0
        for file in files {
            do {
                try fileManager.removeItem(at: file)
                removedCount += 1
            } catch {
                errorCount += 1
            }
        }
        return (removedCount, errorCount)
    }
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum CloudTranscriptionSettings {
    static let timeoutKey = "CloudTranscriptionTimeout"
    static let defaultTimeout = 30

    static var timeout: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: timeoutKey)
        return TimeInterval(stored > 0 ? stored : defaultTimeout)
    }
}

enum AutoLearnSettings {
    static let isEnabledKey = "IsAutoLearnDictionaryEnabled"
    static let providerKey = "AutoLearnDictionaryProvider"
    static let modelKey = "AutoLearnDictionaryModel"
    static let hasFailureKey = "AutoLearnDictionaryHasFailure"
    static let failureMessageKey = "AutoLearnDictionaryFailureMessage"
    static let failureAcknowledgedKey = "AutoLearnDictionaryFailureAcknowledged"
    static let reviewScheduleKey = "AutoLearnDictionaryReviewSchedule"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    static var selectedProvider: AIProvider? {
        guard let value = UserDefaults.standard.string(forKey: providerKey) else { return nil }
        return AIProvider(rawValue: value)
    }

    static var selectedModel: String? {
        let value = UserDefaults.standard.string(forKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static var reviewSchedule: AutoLearnReviewSchedule {
        reviewSchedule(defaults: .standard)
    }

    static func reviewSchedule(defaults: UserDefaults) -> AutoLearnReviewSchedule {
        guard let value = defaults.string(forKey: reviewScheduleKey) else {
            return .manually
        }
        return AutoLearnReviewSchedule(rawValue: value) ?? .manually
    }

    /// Adopts the first configured enhancement provider for Auto Learn.
    /// Once a Dictionary selection exists, provider configuration changes do not replace it.
    static func initializeSelectionIfNeeded(
        provider: AIProvider,
        model: String,
        defaults: UserDefaults = .standard
    ) {
        if let storedProvider = defaults.string(forKey: providerKey),
            let provider = AIProvider(rawValue: storedProvider),
            AutoLearnProviderPolicy.isSupported(provider)
        {
            return
        }

        guard AutoLearnProviderPolicy.isSupported(provider) else { return }

        defaults.set(provider.rawValue, forKey: providerKey)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedModel.isEmpty {
            defaults.removeObject(forKey: modelKey)
        } else {
            defaults.set(selectedModel, forKey: modelKey)
        }
    }

    static func recordFailure(_ error: Error) {
        let nsError = error as NSError
        var details = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason,
            !reason.isEmpty,
            !details.contains(reason)
        {
            details.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion,
            !suggestion.isEmpty,
            !details.contains(suggestion)
        {
            details.append(suggestion)
        }
        let message = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        UserDefaults.standard.set(
            message.isEmpty ? "The selected provider or model could not review corrections." : message,
            forKey: failureMessageKey
        )
        UserDefaults.standard.set(false, forKey: failureAcknowledgedKey)
        UserDefaults.standard.set(true, forKey: hasFailureKey)
    }

    static func clearFailure() {
        UserDefaults.standard.set(false, forKey: hasFailureKey)
        UserDefaults.standard.removeObject(forKey: failureMessageKey)
        UserDefaults.standard.removeObject(forKey: failureAcknowledgedKey)
    }

    static func acknowledgeCurrentFailure(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: failureAcknowledgedKey)
    }
}

enum OnboardingSettings {
    static let completedV2Key = "hasCompletedOnboardingV2"
    static let preparedV2Key = "hasPreparedOnboardingV2"
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            OnboardingSettings.completedV2Key: false,
            OnboardingSettings.preparedV2Key: false,
            "enableAnnouncements": true,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            AudioCaptureSettings.includeSystemAudioKey: false,
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            CloudTranscriptionSettings.timeoutKey: CloudTranscriptionSettings.defaultTimeout,
            AutoLearnSettings.isEnabledKey: true,
            AutoLearnSettings.reviewScheduleKey: AutoLearnReviewSchedule.manually.rawValue,
            RecognitionContextSignalSettings.useAppSignalKey: true,
            RecognitionContextSignalSettings.useURLSignalKey: true,
            RecognitionContextSignalSettings.useModeSignalKey: true,
            ContextPrivacyPolicy.denyListsEnabledDefaultsKey: true,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,
            CleanupSettingsKeys.isAudioHistoryEnabled: false,
            CleanupSettingsKeys.audioHistoryDirectory: "",
            CleanupSettingsKeys.audioHistoryMaximumBytes: AudioHistorySettings.defaultMaximumBytes,

            // UI & Behavior
            "IsMenuBarOnly": false,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Enhancement
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            EnhancementRequestSettings.timeoutKey: EnhancementRequestSettings.defaultTimeoutSeconds,
            EnhancementRequestSettings.retryOnTimeoutKey: EnhancementRequestSettings.defaultRetryOnTimeout,

            // Model
            "PrewarmModelOnWake": true,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
