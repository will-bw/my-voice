import AppKit
import SwiftUI

struct OnboardingTranscriptionSetupCard: View {
    let localModel: TranscribeCppModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: TranscribeCppDownloadStatus?
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownloadLocalModel: (TranscribeCppModel) -> Void
    let onCancelLocalModelDownload: (TranscribeCppModel) -> Void
    let onVerificationChanged: () -> Void

    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isSwitchingProvider = false
    @State private var bailianRegion: BailianRegion = .chinaNorth2
    @State private var bailianWorkspaceID = ""
    @State private var bailianConfigurationMessage: String?

    private var selectedProvider: (any CloudProvider)? {
        providerOptions.first {
            $0.providerKey.caseInsensitiveCompare(selectedProviderKey) == .orderedSame
        } ?? providerOptions.first
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSelectedProviderConnected: Bool {
        guard let selectedProvider else { return false }
        guard APIKeyManager.shared.hasAPIKey(forProvider: selectedProvider.providerKey) else { return false }
        if isBailian {
            guard let saved = try? BailianConfigurationStore.shared.load() else { return false }
            return saved.region == bailianRegion
                && saved.workspaceID == bailianWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return true
    }

    private var canVerify: Bool {
        !trimmedAPIKey.isEmpty && !isVerifying && (!isBailian || isBailianConfigurationValid)
    }

    private var isBailian: Bool {
        selectedProvider?.providerKey.caseInsensitiveCompare("Bailian") == .orderedSame
    }

    private var isBailianConfigurationValid: Bool {
        (try? BailianConfiguration(region: bailianRegion, workspaceID: bailianWorkspaceID)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            setupSwitcher

            switch setupKind {
            case .local:
                localSetup
            case .cloud:
                cloudSetup
            }
        }
        .onAppear {
            if selectedProviderKey.isEmpty, let selectedProvider {
                selectedProviderKey = selectedProvider.providerKey
            }
            loadBailianConfiguration()
            refreshVerificationState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderKeyChanged)) { _ in
            refreshVerificationState()
        }
        .onChange(of: selectedProviderKey) { _, _ in
            handleProviderChange()
        }
        .onChange(of: apiKey) { _, _ in
            guard !apiKey.isEmpty else { return }
            verificationSucceeded = false
            verificationMessage = nil
            verificationDetailMessage = nil
        }
    }

    private var setupSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                setupChoice(.local, systemImage: "macbook")
                setupChoice(.cloud, systemImage: "cloud.fill")
            }

            Text(
                setupKind == .cloud
                    ? "Cloud uses Streaming by default, then Batch, then SenseVoice Small when the offline fallback is installed."
                    : "Local-only mode keeps audio and recognition context on this Mac."
            )
            .font(.system(size: 11))
            .foregroundColor(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(4)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private func setupChoice(_ kind: OnboardingTranscriptionSetupKind, systemImage: String) -> some View {
        let isSelected = setupKind == kind

        return Button {
            onSelectSetupKind(kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))

                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AppTheme.Surface.controlActive : AppTheme.Surface.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var localSetup: some View {
        if let localModel {
            TranscriptionModelDownloadCard(
                model: localModel,
                isDownloaded: isLocalDownloaded,
                isDownloading: isLocalDownloading,
                status: localDownloadStatus,
                onDownload: {
                    onDownloadLocalModel(localModel)
                },
                onCancel: {
                    onCancelLocalModelDownload(localModel)
                }
            )
        } else {
            missingModelPanel
        }
    }

    private var missingModelPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.error)

            Text("SenseVoice Small is not available.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private var cloudSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                providerSummary

                if isBailian && !isSelectedProviderConnected {
                    bailianWorkspaceSetup
                }

                if isSelectedProviderConnected {
                    verifiedProviderSummary
                } else {
                    apiKeyField
                    verificationFooter
                }
            }
            .padding(16)
            .background(AppMaterialCardBackground(cornerRadius: 12))

            offlineFallbackSetup
        }
    }

    @ViewBuilder
    private var offlineFallbackSetup: some View {
        if let localModel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Offline fallback")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                Text(
                    isLocalDownloaded
                        ? "SenseVoice Small is installed and can recover a recording when Streaming and Batch are unavailable."
                        : "Optional now. If skipped, offline recognition and automatic local fallback will be unavailable until you install it later."
                )
                .font(.system(size: 11))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TranscriptionModelDownloadCard(
                    model: localModel,
                    isDownloaded: isLocalDownloaded,
                    isDownloading: isLocalDownloading,
                    status: localDownloadStatus,
                    onDownload: { onDownloadLocalModel(localModel) },
                    onCancel: { onCancelLocalModelDownload(localModel) }
                )
            }
        }
    }

    private var bailianWorkspaceSetup: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Bailian workspace")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Text.primary)

            Picker("Region", selection: $bailianRegion) {
                ForEach(BailianRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .pickerStyle(.menu)

            TextField("Workspace ID, for example ws-xxxxxxxx", text: $bailianWorkspaceID)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                )

            Text("The API key and workspace must belong to the selected region. Official workspace-specific endpoints are used automatically.")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let bailianConfigurationMessage {
                Text(bailianConfigurationMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var providerSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            if let selectedProvider {
                ProviderBrandIcon(
                    descriptor: descriptor(for: selectedProvider),
                    fallbackSystemImage: "captions.bubble.fill",
                    isSelected: true,
                    size: 28,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProvider.providerKey)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                }
            }

            Spacer(minLength: 0)

            if providerOptions.count > 1 {
                Button {
                    isSwitchingProvider.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Switch provider")
                        Image(systemName: isSwitchingProvider ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Text.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.Surface.controlActive))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isSwitchingProvider, arrowEdge: .bottom) {
                    TranscriptionProviderSelectionCard(
                        providerOptions: providerOptions,
                        selectedProviderKey: $selectedProviderKey
                    )
                    .frame(width: 430)
                    .padding(10)
                }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(apiKeyLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Text.primary)

                Spacer()

                if let apiKeyURL {
                    Button {
                        NSWorkspace.shared.open(apiKeyURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Get API key")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            SecureField(apiKeyPlaceholder, text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                )
        }
    }

    private var verificationFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            statusLine

            Spacer(minLength: 12)

            Button(action: verifyAPIKey) {
                HStack(spacing: 6) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(isVerifying ? LocalizedStringKey("Testing...") : LocalizedStringKey("Test connection"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(canVerify ? AppTheme.Action.primaryForeground : AppTheme.Action.disabledForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(canVerify ? AppTheme.Action.primaryFill : AppTheme.Action.disabledFill)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canVerify)
        }
        .padding(.top, 2)
    }

    private var verifiedProviderSummary: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.positive)

            Text("Connection verified.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Text.primary)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let verificationMessage {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: verificationSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verificationMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(verificationSucceeded ? AppTheme.Text.secondary : AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)

                    if let verificationDetailMessage, !verificationSucceeded {
                        Text(verificationDetailMessage)
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.Status.error.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text("Test the connection to continue.")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    private var apiKeyLabel: String {
        guard let selectedProvider else { return String(localized: "API Key") }
        return String(format: String(localized: "%@ API Key"), selectedProvider.providerKey)
    }

    private var apiKeyPlaceholder: String {
        guard let selectedProvider else { return String(localized: "Paste API key") }
        return String(format: String(localized: "Paste %@ API key"), selectedProvider.providerKey)
    }

    private var apiKeyURL: URL? {
        guard let selectedProvider else { return nil }
        return descriptor(for: selectedProvider).apiConsoleURL
    }

    private func refreshVerificationState() {
        verificationSucceeded = isSelectedProviderConnected
        verificationMessage =
            verificationSucceeded
            ? selectedProvider.map {
                String(format: String(localized: "%@ connection verified."), $0.providerKey)
            }
            : nil
        verificationDetailMessage = nil

        if verificationSucceeded {
            apiKey = ""
        }
    }

    private func handleProviderChange() {
        apiKey = ""
        isVerifying = false
        isSwitchingProvider = false
        loadBailianConfiguration()
        refreshVerificationState()
        onVerificationChanged()
    }

    private func verifyAPIKey() {
        let key = trimmedAPIKey
        guard let selectedProvider, !key.isEmpty else { return }

        let bailianConfiguration: BailianConfiguration?
        if isBailian {
            do {
                bailianConfiguration = try BailianConfiguration(
                    region: bailianRegion,
                    workspaceID: bailianWorkspaceID
                )
                bailianConfigurationMessage = nil
            } catch {
                bailianConfigurationMessage = error.localizedDescription
                return
            }
        } else {
            bailianConfiguration = nil
        }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        verificationSucceeded = false
        let providerKey = selectedProvider.providerKey

        Task {
            let result: (isValid: Bool, errorMessage: String?)
            if let bailianConfiguration {
                result = await BailianProvider().verifyAPIKey(
                    key,
                    configuration: bailianConfiguration
                )
            } else {
                result = await selectedProvider.verifyAPIKey(key)
            }

            await MainActor.run {
                isVerifying = false

                guard self.selectedProvider?.providerKey == providerKey else {
                    refreshVerificationState()
                    onVerificationChanged()
                    return
                }

                verificationSucceeded = result.isValid

                if result.isValid {
                    guard APIKeyManager.shared.saveAPIKey(key, forProvider: providerKey) else {
                        verificationSucceeded = false
                        verificationMessage = String(
                            localized: "The key worked, but VoiceInk could not save it securely.")
                        verificationDetailMessage = nil
                        onVerificationChanged()
                        return
                    }

                    if let bailianConfiguration {
                        BailianConfigurationStore.shared.save(bailianConfiguration)
                    }

                    transcriptionModelManager.refreshAllAvailableModels()
                    apiKey = ""
                    verificationMessage = String(format: String(localized: "%@ connection verified."), providerKey)
                    verificationDetailMessage = nil
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and try again.")
                    verificationDetailMessage = result.errorMessage
                }

                onVerificationChanged()
            }
        }
    }

    private func descriptor(for provider: any CloudProvider) -> ProviderDescriptor {
        ProviderDescriptor(
            displayName: provider.providerKey,
            providerKey: provider.providerKey,
            aiProvider: nil,
            cloudProvider: provider
        )
    }

    private func loadBailianConfiguration() {
        guard isBailian else {
            bailianConfigurationMessage = nil
            return
        }
        let draft = BailianConfigurationStore.shared.loadDraft()
        bailianRegion = draft.region
        bailianWorkspaceID = draft.workspaceID
        bailianConfigurationMessage = nil
    }
}

private struct TranscriptionProviderSelectionCard: View {
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(providerOptions.map { $0.providerKey }, id: \.self) { providerKey in
                if let provider = providerOptions.first(where: {
                    $0.providerKey.caseInsensitiveCompare(providerKey) == .orderedSame
                }) {
                    TranscriptionProviderChoiceButton(
                        provider: provider,
                        isSelected: selectedProviderKey.caseInsensitiveCompare(provider.providerKey) == .orderedSame,
                        action: {
                            selectedProviderKey = provider.providerKey
                        }
                    )
                }
            }
        }
        .padding(16)
        .background(ProviderSurface(cornerRadius: 12))
    }
}

private struct TranscriptionProviderChoiceButton: View {
    let provider: any CloudProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ProviderBrandIcon(
                    descriptor: descriptor,
                    fallbackSystemImage: "captions.bubble.fill",
                    isSelected: isSelected,
                    size: 28,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.providerKey)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                        .lineLimit(1)

                    if isRecommended {
                        RecommendedTranscriptionProviderPill()
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(ProviderSurface(isActive: isSelected, cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(provider.providerKey)
    }

    private var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            displayName: provider.providerKey,
            providerKey: provider.providerKey,
            aiProvider: nil,
            cloudProvider: provider
        )
    }

    private var isRecommended: Bool {
        provider.providerKey.caseInsensitiveCompare(OnboardingTranscriptionPolicy.recommendedCloudProviderKey)
            == .orderedSame
    }
}

private struct RecommendedTranscriptionProviderPill: View {
    var body: some View {
        Text("Recommended")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(AppTheme.Text.muted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(AppTheme.Surface.control.opacity(0.55)))
            .overlay(
                Capsule()
                    .stroke(AppTheme.Border.control.opacity(0.28), lineWidth: 1)
            )
    }
}
