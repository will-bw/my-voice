import AppKit
import SwiftUI

struct ProviderDetailPanel: View {
    let descriptor: ProviderDescriptor
    let onClose: () -> Void

    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var isRefreshingOpenRouterModels = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isShowingRemoveAPIKeyConfirmation = false
    @State private var activeDescriptorID = ""
    @State private var bailianRegion: BailianRegion = .chinaNorth2
    @State private var bailianWorkspaceID = ""
    @State private var bailianHTTPEndpoint = ""
    @State private var bailianWebSocketEndpoint = ""
    @State private var isShowingBailianAdvanced = false
    @State private var bailianConfigurationMessage: String?
    @State private var bailianConfigurationIsValid = false
    @State private var hotwordExperimentArm: HotwordExperimentArm = .dynamic
    @State private var useAppRecognitionSignal = true
    @State private var useURLRecognitionSignal = true
    @State private var useModeRecognitionSignal = true
    @State private var contextDenyListsEnabled = true
    @State private var deniedContextApps = ""
    @State private var deniedContextHosts = ""
    @State private var recognitionPrivacyMessage: String?

    private var isBailian: Bool {
        descriptor.providerKey.caseInsensitiveCompare("Bailian") == .orderedSame
    }

    private var isConfigured: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: descriptor.providerKey)
    }

    private var iconName: String {
        if descriptor.hasTranscription && descriptor.hasEnhancement { return "rectangle.2.swap" }
        if descriptor.hasTranscription { return "captions.bubble.fill" }
        return "sparkles"
    }

    var body: some View {
        QuickPanelScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isBailian {
                        bailianConfigurationSection
                        bailianRecognitionHintsSection
                    }

                    apiKeySection

                    if descriptor.hasTranscription {
                        transcriptionModelsSection
                    }

                    if descriptor.hasEnhancement {
                        enhancementModelsSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 76)
                .padding(.bottom, 20)
            }
        } header: {
            header
        }
        .onAppear(perform: loadSavedAPIKey)
        .onChange(of: descriptor.id) { _, _ in
            resetProviderState()
        }
    }

    private var bailianRecognitionHintsSection: some View {
        ProviderConfigurationGroup(title: "Recognition Hints & Privacy") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Hotword comparison path", selection: $hotwordExperimentArm) {
                    Text("No hotwords").tag(HotwordExperimentArm.none)
                    Text("Full dictionary (evaluation only)").tag(HotwordExperimentArm.all)
                    Text("Dynamic Top-K (recommended)").tag(HotwordExperimentArm.dynamic)
                }
                .pickerStyle(.menu)

                Text("The selected path is deterministic and applies to both Streaming and Batch for each recording. Full-dictionary mode is intended only for controlled A/B evaluation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use current app as a local ranking signal", isOn: $useAppRecognitionSignal)
                    Toggle("Use current URL host as a local ranking signal", isOn: $useURLRecognitionSignal)
                    Toggle("Use active Mode as a local ranking signal", isOn: $useModeRecognitionSignal)
                    Text("These switches only affect local hotword ranking. App, URL, and Mode identifiers are not uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Apply custom app and URL deny lists", isOn: $contextDenyListsEnabled)
                    Text("Turn this off to pause your custom rules. Secure controls and unknown security boundaries remain blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Blocked app bundle IDs")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $deniedContextApps)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.Border.control.opacity(0.7)))
                        .disabled(!contextDenyListsEnabled)
                    Text("One bundle ID per line. Initially empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Blocked URL hosts")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $deniedContextHosts)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.Border.control.opacity(0.7)))
                        .disabled(!contextDenyListsEnabled)
                    Text("One host per line; subdomains are also blocked. Initially empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Before a request, my-voice checks the focused control and these deny lists. Only source types and counts are logged; raw context and hotword lists are not logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Save Hint Settings") { saveRecognitionHintSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if let recognitionPrivacyMessage {
                        Label(recognitionPrivacyMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Status.positive)
                    }
                }
            }
            .padding(12)
            .background(ProviderSurface(cornerRadius: 8))
        }
    }

    private var bailianConfigurationSection: some View {
        ProviderConfigurationGroup(title: "Bailian Workspace") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Region", selection: $bailianRegion) {
                    ForEach(BailianRegion.allCases, id: \.self) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace ID")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("For example: ws-xxxxxxxx", text: $bailianWorkspaceID)
                        .textFieldStyle(.roundedBorder)
                    Text("The API key, HTTP endpoint, and WebSocket endpoint must belong to this region and workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Advanced endpoints", isExpanded: $isShowingBailianAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Custom HTTPS endpoint (optional)", text: $bailianHTTPEndpoint)
                            .textFieldStyle(.roundedBorder)
                        TextField("Custom WSS endpoint (optional)", text: $bailianWebSocketEndpoint)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave both fields empty to use the workspace-specific official endpoints.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                HStack(spacing: 10) {
                    Button("Save Workspace") {
                        saveBailianConfiguration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(bailianWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let bailianConfigurationMessage {
                        Label(
                            bailianConfigurationMessage,
                            systemImage: bailianConfigurationIsValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            bailianConfigurationIsValid ? AppTheme.Status.positive : AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(ProviderSurface(cornerRadius: 8))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProviderBrandIcon(
                descriptor: descriptor,
                fallbackSystemImage: iconName,
                isSelected: false,
                size: 38,
                iconSize: 18
            )

            Text(descriptor.displayName)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onClose
            )
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.headerHeight)
    }

    private var apiKeySection: some View {
        ProviderConfigurationGroup(title: "Connection") {
            VStack(alignment: .leading, spacing: 8) {
                if isConfigured {
                    verifiedAPIKeyRow
                } else {
                    apiKeyInputRow
                }

                verificationStatusMessage
            }
        }
    }

    @ViewBuilder
    private var verificationStatusMessage: some View {
        if let verificationMessage {
            VStack(alignment: .leading, spacing: 3) {
                Text(verificationMessage)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)

                if let verificationDetailMessage, !verificationSucceeded {
                    Text(verificationDetailMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var verifiedAPIKeyRow: some View {
        HStack(spacing: 12) {
            providerDetailIcon("checkmark.seal.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text("Key verified")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let obfuscatedKey {
                    Text(obfuscatedKey)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                isShowingRemoveAPIKeyConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Remove API key")
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
        .alert("Remove API Key?", isPresented: $isShowingRemoveAPIKeyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeAPIKey()
            }
        } message: {
            Text(
                String(
                    format: String(localized: "This will remove your %@ API key. You can add it again later."),
                    descriptor.displayName))
        }
    }

    private var apiKeyInputRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                providerDetailIcon("key.fill")

                VStack(alignment: .leading, spacing: 3) {
                    Text("API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 8) {
                SecureField("Paste API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isVerifying)
                    .onChange(of: apiKey) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        verificationMessage = nil
                        verificationDetailMessage = nil
                    }

                Button {
                    verifyAndSaveAPIKey()
                } label: {
                    HStack(spacing: 5) {
                        if isVerifying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(isVerifying ? LocalizedStringKey("Verifying") : LocalizedStringKey("Verify"))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying)
                .opacity(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifying ? 0.55 : 1)
            }

            if let consoleURL = descriptor.apiConsoleURL {
                Link(destination: consoleURL) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))

                        Text(String(format: String(localized: "Get %@ API Key"), descriptor.displayName))
                            .font(.system(size: 12, weight: .medium))

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(neutralLinkButtonBackground)
                }
                .buttonStyle(.plain)
                .help(String(format: String(localized: "Open %@ API key page"), descriptor.displayName))
            }
        }
        .padding(12)
        .background(ProviderSurface(cornerRadius: 8))
    }

    private func providerDetailIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var neutralLinkButtonBackground: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(AppTheme.Surface.control)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
            )
    }

    private var transcriptionModelsSection: some View {
        let models = descriptor.transcriptionModels

        return ProviderModelListSection(title: "Available Transcription Models") {
            ForEach(Array(models.prefix(8).enumerated()), id: \.element.id) { index, model in
                modelRow(
                    title: model.displayName,
                    subtitle: nil,
                    trailing: nil,
                    systemImage: "captions.bubble.fill"
                )

                if index < min(models.count, 8) - 1 {
                    Divider()
                }
            }

            if models.count > 8 {
                Divider()
                Text("More transcription models available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var enhancementModelsSection: some View {
        if let provider = descriptor.aiProvider {
            let models = aiService.availableModels(for: provider)

            ProviderModelListSection(title: "Available Enhancement Models") {
                if provider == .openRouter {
                    HStack(spacing: 12) {
                        Text(openRouterModelAvailabilityText(for: models.count))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(models.isEmpty ? .secondary : .primary)

                        Spacer()

                        Button {
                            refreshOpenRouterModels()
                        } label: {
                            HStack(spacing: 5) {
                                if isRefreshingOpenRouterModels {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(
                                    isRefreshingOpenRouterModels
                                        ? LocalizedStringKey("Refreshing") : LocalizedStringKey("Refresh"))
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshingOpenRouterModels)
                        .opacity(isRefreshingOpenRouterModels ? 0.55 : 1)
                    }
                    .padding(.vertical, 8)
                } else if models.isEmpty {
                    Text("No models listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(models.prefix(8).enumerated()), id: \.offset) { index, model in
                        modelRow(
                            title: model,
                            subtitle: nil,
                            trailing: nil,
                            systemImage: "sparkles"
                        )

                        if index < min(models.count, 8) - 1 {
                            Divider()
                        }
                    }

                    if models.count > 8 {
                        Divider()
                        Text("More enhancement models available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }

            }
        }
    }

    private func openRouterModelAvailabilityText(for count: Int) -> String {
        if count == 0 {
            return String(localized: "No models loaded.")
        }

        return String(localized: "\(count) models available")
    }

    private func modelRow(title: String, subtitle: String?, trailing: String?, systemImage: String) -> some View {
        HStack(spacing: 10) {
            modelTypeIcon(systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func modelTypeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Surface.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                    )
            )
    }

    private var obfuscatedKey: String? {
        guard let savedKey = APIKeyManager.shared.getAPIKey(forProvider: descriptor.providerKey) else {
            return nil
        }

        let trimmedKey = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        if trimmedKey.count <= 8 {
            return String(repeating: "\u{2022}", count: trimmedKey.count)
        }

        return
            "\(trimmedKey.prefix(4))\(String(repeating: "\u{2022}", count: max(4, trimmedKey.count - 8)))\(trimmedKey.suffix(4))"
    }

    private func loadSavedAPIKey() {
        resetProviderState()
    }

    private func resetProviderState() {
        activeDescriptorID = descriptor.id
        verificationSucceeded = isConfigured
        apiKey = ""
        isVerifying = false
        isRefreshingOpenRouterModels = false
        verificationMessage = nil
        verificationDetailMessage = nil
        isShowingRemoveAPIKeyConfirmation = false
        loadBailianConfiguration()
    }

    private func verificationModel(for provider: AIProvider) -> String {
        let selectedModel = aiService.selectedModel(for: provider)
        let models = aiService.availableModels(for: provider)

        if models.contains(selectedModel) {
            return selectedModel
        }

        return models.first ?? selectedModel
    }

    private func verifyAndSaveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        if isBailian, !persistBailianConfiguration() { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        let providerID = descriptor.id

        Task {
            let result: (isValid: Bool, errorMessage: String?)
            if let cloudProvider = descriptor.cloudProvider {
                result = await cloudProvider.verifyAPIKey(trimmedKey)
            } else if let provider = descriptor.aiProvider {
                result = await aiService.verifyAPIKey(
                    trimmedKey,
                    for: provider,
                    model: verificationModel(for: provider)
                )
            } else {
                result = (false, String(localized: "Provider is not supported"))
            }

            await MainActor.run {
                guard activeDescriptorID == providerID else { return }

                isVerifying = false
                verificationSucceeded = result.isValid

                if result.isValid {
                    APIKeyManager.shared.saveAPIKey(trimmedKey, forProvider: descriptor.providerKey)
                    if let provider = descriptor.aiProvider, aiService.selectedProvider == provider {
                        aiService.apiKey = trimmedKey
                        aiService.isAPIKeyValid = true
                    }
                    apiKey = ""
                    verificationMessage = nil
                    verificationDetailMessage = nil
                    transcriptionModelManager.refreshAllAvailableModels()
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and try again.")
                    verificationDetailMessage = result.errorMessage
                }
            }
        }
    }

    private func loadBailianConfiguration() {
        guard isBailian else { return }
        let draft = BailianConfigurationStore.shared.loadDraft()
        bailianRegion = draft.region
        bailianWorkspaceID = draft.workspaceID
        bailianHTTPEndpoint = draft.httpEndpoint
        bailianWebSocketEndpoint = draft.webSocketEndpoint
        bailianConfigurationMessage = nil
        bailianConfigurationIsValid = false
        hotwordExperimentArm = HotwordExperimentArm.current
        useAppRecognitionSignal = RecognitionContextSignalSettings.usesApp()
        useURLRecognitionSignal = RecognitionContextSignalSettings.usesURL()
        useModeRecognitionSignal = RecognitionContextSignalSettings.usesMode()
        contextDenyListsEnabled = ContextPrivacyPolicy.areDenyListsEnabled()
        deniedContextApps = (UserDefaults.standard.stringArray(
            forKey: ContextPrivacyPolicy.deniedAppsDefaultsKey) ?? []).joined(separator: "\n")
        deniedContextHosts = (UserDefaults.standard.stringArray(
            forKey: ContextPrivacyPolicy.deniedHostsDefaultsKey) ?? []).joined(separator: "\n")
        recognitionPrivacyMessage = nil
    }

    private func saveRecognitionHintSettings() {
        UserDefaults.standard.set(hotwordExperimentArm.rawValue, forKey: HotwordExperimentArm.defaultsKey)
        UserDefaults.standard.set(
            useAppRecognitionSignal, forKey: RecognitionContextSignalSettings.useAppSignalKey)
        UserDefaults.standard.set(
            useURLRecognitionSignal, forKey: RecognitionContextSignalSettings.useURLSignalKey)
        UserDefaults.standard.set(
            useModeRecognitionSignal, forKey: RecognitionContextSignalSettings.useModeSignalKey)
        UserDefaults.standard.set(
            contextDenyListsEnabled, forKey: ContextPrivacyPolicy.denyListsEnabledDefaultsKey)
        UserDefaults.standard.set(normalizedLines(deniedContextApps), forKey: ContextPrivacyPolicy.deniedAppsDefaultsKey)
        UserDefaults.standard.set(normalizedLines(deniedContextHosts), forKey: ContextPrivacyPolicy.deniedHostsDefaultsKey)
        recognitionPrivacyMessage = String(localized: "Hint and privacy settings saved.")
    }

    private func normalizedLines(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(whereSeparator: \Character.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private func saveBailianConfiguration() {
        _ = persistBailianConfiguration()
    }

    @discardableResult
    private func persistBailianConfiguration() -> Bool {
        do {
            _ = try BailianConfigurationStore.shared.validateAndSave(
                region: bailianRegion,
                workspaceID: bailianWorkspaceID,
                httpEndpoint: bailianHTTPEndpoint,
                webSocketEndpoint: bailianWebSocketEndpoint
            )
            bailianConfigurationMessage = String(localized: "Workspace saved. Verify the connection before use.")
            bailianConfigurationIsValid = true
            verificationSucceeded = false
            return true
        } catch {
            bailianConfigurationMessage = error.localizedDescription
            bailianConfigurationIsValid = false
            return false
        }
    }

    private func removeAPIKey() {
        APIKeyManager.shared.deleteAPIKey(forProvider: descriptor.providerKey)
        apiKey = ""
        verificationSucceeded = false
        verificationMessage = nil
        verificationDetailMessage = nil
        transcriptionModelManager.refreshAllAvailableModels()
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    private func refreshOpenRouterModels() {
        guard !isRefreshingOpenRouterModels else { return }
        isRefreshingOpenRouterModels = true

        Task {
            await aiService.fetchOpenRouterModels()
            await MainActor.run {
                isRefreshingOpenRouterModels = false
            }
        }
    }

}
