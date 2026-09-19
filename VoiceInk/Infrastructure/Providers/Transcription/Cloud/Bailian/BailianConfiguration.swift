import Foundation

enum BailianRegion: String, Codable, CaseIterable, Sendable {
    case chinaNorth2 = "cn-beijing"
    case singapore = "ap-southeast-1"

    var displayName: String {
        switch self {
        case .chinaNorth2: "华北 2（北京）"
        case .singapore: "新加坡"
        }
    }
}

struct BailianConfiguration: Equatable, Sendable {
    static let batchModel = "qwen-audio-3.0-asr-flash"
    static let streamingModel = "qwen-audio-3.0-asr-flash-streaming"

    let region: BailianRegion
    let workspaceID: String
    let customHTTPEndpoint: URL?
    let customWebSocketEndpoint: URL?

    init(
        region: BailianRegion,
        workspaceID: String,
        customHTTPEndpoint: URL? = nil,
        customWebSocketEndpoint: URL? = nil
    ) throws {
        let normalizedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidWorkspaceID(normalizedWorkspaceID) else {
            throw BailianError.misconfigured("Workspace ID 无效")
        }
        if let customHTTPEndpoint,
            customHTTPEndpoint.scheme?.lowercased() != "https" || customHTTPEndpoint.host?.isEmpty != false
        {
            throw BailianError.misconfigured("HTTP 端点必须使用 HTTPS")
        }
        if let customWebSocketEndpoint,
            customWebSocketEndpoint.scheme?.lowercased() != "wss" || customWebSocketEndpoint.host?.isEmpty != false
        {
            throw BailianError.misconfigured("WebSocket 端点必须使用 WSS")
        }

        self.region = region
        self.workspaceID = normalizedWorkspaceID
        self.customHTTPEndpoint = customHTTPEndpoint
        self.customWebSocketEndpoint = customWebSocketEndpoint
    }

    var httpEndpoint: URL {
        customHTTPEndpoint
            ?? URL(
                string:
                    "https://\(workspaceID).\(region.rawValue).maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
            )!
    }

    var webSocketEndpoint: URL {
        customWebSocketEndpoint
            ?? URL(
                string: "wss://\(workspaceID).\(region.rawValue).maas.aliyuncs.com/api-ws/v1/inference"
            )!
    }

    private static func isValidWorkspaceID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 63, value.first != "-", value.last != "-" else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
}

final class BailianConfigurationStore {
    static let shared = BailianConfigurationStore()

    private enum Key {
        static let region = "BailianRegion"
        static let workspaceID = "BailianWorkspaceID"
        static let httpEndpoint = "BailianHTTPEndpoint"
        static let webSocketEndpoint = "BailianWebSocketEndpoint"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> BailianConfiguration {
        let region = defaults.string(forKey: Key.region).flatMap(BailianRegion.init(rawValue:)) ?? .chinaNorth2
        let workspaceID = defaults.string(forKey: Key.workspaceID) ?? ""
        let httpEndpoint = defaults.string(forKey: Key.httpEndpoint).flatMap(URL.init(string:))
        let webSocketEndpoint = defaults.string(forKey: Key.webSocketEndpoint).flatMap(URL.init(string:))
        return try BailianConfiguration(
            region: region,
            workspaceID: workspaceID,
            customHTTPEndpoint: httpEndpoint,
            customWebSocketEndpoint: webSocketEndpoint
        )
    }

    func loadDraft() -> (region: BailianRegion, workspaceID: String, httpEndpoint: String, webSocketEndpoint: String) {
        (
            defaults.string(forKey: Key.region).flatMap(BailianRegion.init(rawValue:)) ?? .chinaNorth2,
            defaults.string(forKey: Key.workspaceID) ?? "",
            defaults.string(forKey: Key.httpEndpoint) ?? "",
            defaults.string(forKey: Key.webSocketEndpoint) ?? ""
        )
    }

    @discardableResult
    func validateAndSave(
        region: BailianRegion,
        workspaceID: String,
        httpEndpoint: String,
        webSocketEndpoint: String
    ) throws -> BailianConfiguration {
        let trimmedHTTP = httpEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebSocket = webSocketEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHTTP.isEmpty || URL(string: trimmedHTTP) != nil else {
            throw BailianError.misconfigured("HTTP 端点格式无效")
        }
        guard trimmedWebSocket.isEmpty || URL(string: trimmedWebSocket) != nil else {
            throw BailianError.misconfigured("WebSocket 端点格式无效")
        }
        let configuration = try BailianConfiguration(
            region: region,
            workspaceID: workspaceID,
            customHTTPEndpoint: trimmedHTTP.isEmpty ? nil : URL(string: trimmedHTTP),
            customWebSocketEndpoint: trimmedWebSocket.isEmpty ? nil : URL(string: trimmedWebSocket)
        )
        save(configuration)
        return configuration
    }

    func save(_ configuration: BailianConfiguration) {
        defaults.set(configuration.region.rawValue, forKey: Key.region)
        defaults.set(configuration.workspaceID, forKey: Key.workspaceID)
        defaults.set(configuration.customHTTPEndpoint?.absoluteString, forKey: Key.httpEndpoint)
        defaults.set(configuration.customWebSocketEndpoint?.absoluteString, forKey: Key.webSocketEndpoint)
        Task { await BailianProviderHealthStore.shared.reset() }
    }
}
