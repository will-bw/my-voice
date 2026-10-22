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
    case requestRejected(statusCode: Int)
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
        case .requestRejected(let statusCode): "百炼拒绝了本次转写请求（HTTP \(statusCode)），下次录音将重试"
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
        case .misconfigured:
            return .misconfigured
        case .emptyFinal:
            return .healthy
        case .rateLimited, .server, .timeout, .network, .disconnected, .canceled,
             .protocolViolation, .invalidResponse, .requestRejected:
            return .transientFailure
        }
    }
}

actor BailianProviderHealthStore {
    static let shared = BailianProviderHealthStore()

    private(set) var health: BailianProviderHealth = .unknown
    private let retryDelay: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var blockedUntil: ContinuousClock.Instant?

    init(
        retryDelay: Duration = .seconds(30),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.retryDelay = retryDelay
        self.now = now
    }

    func markHealthy() {
        health = .healthy
        blockedUntil = nil
    }

    func record(_ error: Error) {
        let classification = BailianProviderHealth.classify(error)
        switch classification {
        case .invalidCredential, .misconfigured:
            // A locally suppressed attempt must not move the recovery deadline forward.
            if classification != health || blockedUntil == nil {
                blockedUntil = now().advanced(by: retryDelay)
            }
        case .unknown, .healthy, .transientFailure:
            blockedUntil = nil
        }
        health = classification
    }

    func reset() {
        health = .unknown
        blockedUntil = nil
    }

    func ensureAttemptAllowed() throws {
        if let blockedUntil, now() >= blockedUntil {
            reset()
        }
        switch health {
        case .invalidCredential:
            throw BailianError.invalidCredential(statusCode: 401)
        case .misconfigured:
            throw BailianError.misconfigured("请检查百炼配置，稍后将自动重试")
        case .unknown, .healthy, .transientFailure:
            return
        }
    }
}

enum BailianErrorMapper {
    static func map(statusCode: Int, responseBody: Data? = nil) -> BailianError {
        // A silent recording is a per-request ASR result, not a configuration failure.
        // Inspect only structured error fields; never include the raw response in logs.
        if statusCode == 400,
           let responseBody,
           let body = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           isNoWords(code: body["code"] as? String, message: body["message"] as? String)
        {
            return .emptyFinal
        }
        switch statusCode {
        case 401, 403: return .invalidCredential(statusCode: statusCode)
        case 429: return .rateLimited
        case 500...599: return .server(statusCode: statusCode)
        // Gateways can return {} for a silent recording. HTTP status alone cannot
        // establish that the user's persistent configuration is invalid.
        case 400...499: return .requestRejected(statusCode: statusCode)
        default: return .invalidResponse("HTTP \(statusCode)")
        }
    }

    static func mapWebSocketFailure(statusCode: Int?, underlyingError: Error) -> BailianError {
        // task.response retains the successful upgrade response for the connection's lifetime.
        if let statusCode, statusCode != 101, !(200...299).contains(statusCode) {
            return map(statusCode: statusCode)
        }
        return map(underlyingError)
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
        if isNoWords(code: code, message: message) {
            return .emptyFinal
        }
        if combined.contains("rate") || combined.contains("throttl") || combined.contains("limit") {
            return .rateLimited
        }
        if combined.contains("timeout") || combined.contains("timed out") {
            return .timeout
        }
        if normalizedCode.contains("client") {
            return .requestRejected(statusCode: 400)
        }
        return .server(statusCode: 500)
    }

    private static func isNoWords(code: String?, message: String?) -> Bool {
        let marker = "ASR_RESPONSE_HAVE_NO_WORDS"
        return code?.uppercased() == marker || message?.uppercased().contains(marker) == true
    }
}
