import Foundation
import XCTest
@testable import VoiceInk

private actor MockWebSocketTransport: BailianWebSocketTransport {
    private(set) var request: URLRequest?
    private(set) var sent: [BailianWebSocketMessage] = []
    private(set) var isClosed = false
    var connectError: Error?
    private var queued: [Result<BailianWebSocketMessage, Error>] = []
    private var waiters: [CheckedContinuation<BailianWebSocketMessage, Error>] = []

    func connect(request: URLRequest) async throws {
        if let connectError { throw connectError }
        self.request = request
    }

    func send(_ message: BailianWebSocketMessage) async throws {
        if isClosed { throw BailianError.disconnected }
        sent.append(message)
    }

    func receive() async throws -> BailianWebSocketMessage {
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        isClosed = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume(throwing: CancellationError()) }
    }

    func push(_ message: BailianWebSocketMessage) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: message)
        } else {
            queued.append(.success(message))
        }
    }

    func failReceive(_ error: Error) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(throwing: error)
        } else {
            queued.append(.failure(error))
        }
    }

    func sentMessages() -> [BailianWebSocketMessage] { sent }
    func closed() -> Bool { isClosed }
}

final class BailianStreamingSessionTests: XCTestCase {
    private func makeSession() throws -> (BailianStreamingSession, MockWebSocketTransport) {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
        let transport = MockWebSocketTransport()
        return (
            BailianStreamingSession(
                configuration: configuration,
                transport: transport,
                healthStore: BailianProviderHealthStore()
            ),
            transport
        )
    }

    private func taskID(from transport: MockWebSocketTransport) async throws -> String {
        let messages = await transport.sentMessages()
        guard case .text(let text) = try XCTUnwrap(messages.first) else {
            throw BailianError.invalidResponse("run-task missing")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let header = try XCTUnwrap(json["header"] as? [String: Any])
        return try XCTUnwrap(header["task_id"] as? String)
    }

    private func started(_ taskID: String) -> String {
        #"{"header":{"task_id":"\#(taskID)","event":"task-started"},"payload":{}}"#
    }

    private func result(_ taskID: String, id: Int, text: String, isFinal: Bool) -> String {
        #"{"header":{"task_id":"\#(taskID)","event":"result-generated"},"payload":{"output":{"sentence":{"text":"\#(text)","sentence_end":\#(isFinal),"sentence_id":\#(id)}}}}"#
    }

    private func finished(_ taskID: String) -> String {
        #"{"header":{"task_id":"\#(taskID)","event":"task-finished"},"payload":{}}"#
    }

    private func failed(_ taskID: String, code: String, message: String) -> String {
        #"{"header":{"task_id":"\#(taskID)","event":"task-failed","error_code":"\#(code)","error_message":"\#(message)"},"payload":{}}"#
    }

    func testNormalFlowSortsOutOfOrderSentencesAndDeduplicates() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(
            apiKey: "secret",
            hints: BailianRecognitionHints(vocabulary: ["百炼": 4], languageHints: ["zh"], context: "项目词表")
        )
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        try await session.sendAudio(Data([1, 2, 3]))

        let finalTask = Task { try await session.finish(timeout: .seconds(1)) }
        await Task.yield()
        await session.handleServerText(result(id, id: 2, text: "二", isFinal: true))
        await session.handleServerText(result(id, id: 1, text: "一", isFinal: true))
        await session.handleServerText(result(id, id: 1, text: "一", isFinal: true))
        await session.handleServerText(finished(id))

        let finalText = try await finalTask.value
        XCTAssertEqual(finalText, "一二")
        let sent = await transport.sentMessages()
        XCTAssertTrue(sent.contains(.data(Data([1, 2, 3]))))
        XCTAssertTrue(sent.contains { message in
            guard case .text(let text) = message else { return false }
            return text.contains("finish-task")
        })
    }

    func testResultBeforeTaskStartedFailsProtocol() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(result(id, id: 1, text: "early", isFinal: false))
        let closedAfterProtocolFailure = await transport.closed()
        XCTAssertTrue(closedAfterProtocolFailure)
        do {
            try await session.sendAudio(Data([1]))
            XCTFail("Expected protocol failure")
        } catch let error as BailianError {
            XCTAssertEqual(error, .protocolViolation("收到 task-started 前不能发送音频"))
        }
    }

    func testAudioCannotBeSentBeforeTaskStarted() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        do {
            try await session.sendAudio(Data([1]))
            XCTFail("Expected pre-start audio to fail")
        } catch let error as BailianError {
            XCTAssertEqual(error, .protocolViolation("收到 task-started 前不能发送音频"))
        }
        let closed = await transport.closed()
        XCTAssertTrue(closed)
    }

    func testUnknownServerFieldsAreIgnored() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(
            #"{"header":{"task_id":"\#(id)","event":"task-started","future":"ignored"},"payload":{"new_field":true}}"#
        )
        let finalTask = Task { try await session.finish(timeout: .seconds(1)) }
        await Task.yield()
        await session.handleServerText(
            #"{"header":{"task_id":"\#(id)","event":"result-generated"},"payload":{"output":{"sentence":{"text":"兼容","sentence_end":true,"sentence_id":1,"future":42}}}}"#
        )
        await session.handleServerText(finished(id))
        let finalText = try await finalTask.value
        XCTAssertEqual(finalText, "兼容")
    }

    func testPartialRevisionEmitsLatestTextWithoutCommittingEarly() async throws {
        let (session, transport) = try makeSession()
        var outputs = session.outputs.makeAsyncIterator()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)

        await session.handleServerText(started(id))
        await session.handleServerText(result(id, id: 1, text: "草", isFinal: false))
        await session.handleServerText(result(id, id: 1, text: "草稿", isFinal: false))
        await session.handleServerText(result(id, id: 1, text: "草稿完成", isFinal: true))

        let startedOutput = await outputs.next()
        let firstPartial = await outputs.next()
        let revisedPartial = await outputs.next()
        let committed = await outputs.next()
        XCTAssertEqual(startedOutput, .sessionStarted)
        XCTAssertEqual(firstPartial, .partial("草"))
        XCTAssertEqual(revisedPartial, .partial("草稿"))
        XCTAssertEqual(committed, .committed("草稿完成"))
        await session.cancel()
    }

    func testEmptyFinalFails() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        let finalTask = Task { try await session.finish(timeout: .seconds(1)) }
        await Task.yield()
        await session.handleServerText(finished(id))
        do {
            _ = try await finalTask.value
            XCTFail("Expected empty final")
        } catch let error as BailianError {
            XCTAssertEqual(error, .emptyFinal)
        }
    }

    func testTimeoutClosesConnection() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        do {
            _ = try await session.finish(timeout: .milliseconds(10))
            XCTFail("Expected timeout")
        } catch let error as BailianError {
            XCTAssertEqual(error, .timeout)
        }
        let closedAfterTimeout = await transport.closed()
        XCTAssertTrue(closedAfterTimeout)
    }

    func testTaskFailedClassifiesAndClosesConnection() async throws {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
        let transport = MockWebSocketTransport()
        let healthStore = BailianProviderHealthStore()
        let session = BailianStreamingSession(
            configuration: configuration,
            transport: transport,
            healthStore: healthStore
        )
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        await session.handleServerText(failed(id, code: "CLIENT_ERROR", message: "Invalid API key"))

        let health = await healthStore.health
        let closedAfterFailure = await transport.closed()
        XCTAssertEqual(health, .invalidCredential)
        XCTAssertTrue(closedAfterFailure)
    }

    func testDisconnectAndCancelRaceDoNotProduceLateFinal() async throws {
        let (session, transport) = try makeSession()
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        await session.cancel()
        await session.handleServerText(result(id, id: 1, text: "不得投递", isFinal: true))
        await session.handleServerText(finished(id))
        let closedAfterCancel = await transport.closed()
        XCTAssertTrue(closedAfterCancel)

        let (disconnectedSession, disconnectedTransport) = try makeSession()
        try await disconnectedSession.connect(apiKey: "secret", hints: BailianRecognitionHints())
        await disconnectedTransport.failReceive(URLError(.networkConnectionLost))
        try await Task.sleep(for: .milliseconds(20))
        let closedAfterDisconnect = await disconnectedTransport.closed()
        XCTAssertTrue(closedAfterDisconnect)
    }
}
