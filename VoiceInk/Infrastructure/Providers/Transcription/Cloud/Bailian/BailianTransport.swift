import Foundation

protocol BailianHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct BailianURLSessionHTTPTransport: BailianHTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BailianError.invalidResponse("缺少 HTTP 响应")
        }
        return (data, response)
    }
}

enum BailianWebSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

protocol BailianWebSocketTransport: AnyObject, Sendable {
    func connect(request: URLRequest) async throws
    func send(_ message: BailianWebSocketMessage) async throws
    func receive() async throws -> BailianWebSocketMessage
    func close() async
}

final class BailianURLSessionWebSocketTransport: BailianWebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws {
        let newTask = session.webSocketTask(with: request)
        lock.withLock { task = newTask }
        newTask.resume()
    }

    func send(_ message: BailianWebSocketMessage) async throws {
        guard let task = lock.withLock({ task }) else { throw BailianError.disconnected }
        do {
            switch message {
            case .text(let text): try await task.send(.string(text))
            case .data(let data): try await task.send(.data(data))
            }
        } catch {
            throw mappedHandshakeError(task: task, fallback: error)
        }
    }

    func receive() async throws -> BailianWebSocketMessage {
        guard let task = lock.withLock({ task }) else { throw BailianError.disconnected }
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: throw BailianError.invalidResponse("未知 WebSocket 消息")
            }
        } catch {
            throw mappedHandshakeError(task: task, fallback: error)
        }
    }

    func close() async {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func mappedHandshakeError(task: URLSessionWebSocketTask, fallback: Error) -> Error {
        BailianErrorMapper.mapWebSocketFailure(
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            underlyingError: fallback
        )
    }
}
