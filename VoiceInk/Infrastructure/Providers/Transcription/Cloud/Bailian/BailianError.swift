import Foundation

enum BailianError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidCredential(statusCode: Int)
    case rateLimited
    case server(statusCode: Int)
    case timeout
    case network(String)
    case disconnected
    case canceled
    case misconfigured(String)
    case invalidResponse(String)
    case emptyFinal
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "未配置百炼 API Key"
        case .invalidCredential: "百炼 API Key 无效或无权访问当前地域/业务空间"
        case .rateLimited: "百炼请求受到限流"
        case .server(let statusCode): "百炼服务暂时不可用（HTTP \(statusCode)）"
        case .timeout: "百炼请求超时"
        case .network: "无法连接百炼服务"
        case .disconnected: "百炼实时连接已中断"
        case .canceled: "百炼请求已取消"
        case .misconfigured(let message): "百炼配置错误：\(message)"
        case .invalidResponse(let message): "百炼响应无效：\(message)"
        case .emptyFinal: "百炼未返回有效识别文本"
        case .protocolViolation(let message): "百炼协议状态错误：\(message)"
        }
    }
}

enum BailianProviderHealth: Equatable, Sendable {
    case unknown
    case healthy
    case transientFailure
    case invalidCredential
    case misconfigured

    static func classify(_ error: Error) -> BailianProviderHealth {
        guard let error = error as? BailianError else { return .transientFailure }
        switch error {
        case .invalidCredential, .missingAPIKey:
            return .invalidCredential
        case .misconfigured, .protocolViolation, .invalidResponse:
            return .misconfigured
        case .emptyFinal:
            return .healthy
        case .rateLimited, .server, .timeout, .network, .disconnected, .canceled:
            return .transientFailure
        }
    }
}

actor BailianProviderHealthStore {
    static let shared = BailianProviderHealthStore()

    private(set) var health: BailianProviderHealth = .unknown

    func markHealthy() {
        health = .healthy
    }

    func record(_ error: Error) {
        health = .classify(error)
    }

    func reset() {
        health = .unknown
    }

    func ensureAttemptAllowed() throws {
        switch health {
        case .invalidCredential:
            throw BailianError.invalidCredential(statusCode: 401)
        case .misconfigured:
            throw BailianError.misconfigured("请先更新百炼配置")
        case .unknown, .healthy, .transientFailure:
            return
        }
    }
}

enum BailianErrorMapper {
    static func map(statusCode: Int, responseBody: Data? = nil) -> BailianError {
        switch statusCode {
        case 401, 403: .invalidCredential(statusCode: statusCode)
        case 429: .rateLimited
        case 500...599: .server(statusCode: statusCode)
        case 400...499: .misconfigured("HTTP \(statusCode)")
        default: .invalidResponse("HTTP \(statusCode)")
        }
    }

    static func map(_ error: Error) -> BailianError {
        if let error = error as? BailianError { return error }
        if error is CancellationError { return .canceled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .canceled
            default: return .network(String(describing: urlError.code))
            }
        }
        return .network(String(describing: type(of: error)))
    }

    static func mapTaskFailure(code: String?, message: String?) -> BailianError {
        let normalizedCode = (code ?? "").lowercased()
        let normalizedMessage = (message ?? "").lowercased()
        let combined = "\(normalizedCode) \(normalizedMessage)"

        if combined.contains("auth")
            || combined.contains("unauthor")
            || combined.contains("api key")
            || combined.contains("apikey")
            || combined.contains("permission")
        {
            return .invalidCredential(statusCode: 401)
        }
        if combined.contains("rate") || combined.contains("throttl") || combined.contains("limit") {
            return .rateLimited
        }
        if combined.contains("timeout") || combined.contains("timed out") {
            return .timeout
        }
        if normalizedCode.contains("client") {
            return .misconfigured("服务端拒绝了请求参数")
        }
        return .server(statusCode: 500)
    }
}
