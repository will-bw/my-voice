import Foundation
import XCTest
@testable import VoiceInk

private actor MockWebSocketTransport: BailianWebSocketTransport {
    private(set) var request: URLRequest?
    private(set) var sent: [BailianWebSocketMessage] = []
    private(set) var isClosed = false
    var connectError: Error?
    private var stallSend = false
    private var sendWaiter: CheckedContinuation<Void, Error>?
    private var queued: [Result<BailianWebSocketMessage, Error>] = []
    private var waiters: [CheckedContinuation<BailianWebSocketMessage, Error>] = []

    func connect(request: URLRequest) async throws {
        if let connectError { throw connectError }
        self.request = request
    }

    func send(_ message: BailianWebSocketMessage) async throws {
        if isClosed { throw BailianError.disconnected }
        sent.append(message)
        if stallSend {
            try await withCheckedThrowingContinuation { sendWaiter = $0 }
        }
    }

    func receive() async throws -> BailianWebSocketMessage {
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        isClosed = true
        sendWaiter?.resume(throwing: CancellationError())
        sendWaiter = nil
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
    func blockSend() { stallSend = true }
}

private struct NoWordsHTTPTransport: BailianHTTPTransport {
    var json = #"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS"}"#
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        )
    }
}

final class BailianStreamingSessionTests: XCTestCase {
    func testBlockedAudioSendTimesOutAndAllowsNextSession() async throws {
        let health = BailianProviderHealthStore()
        let transport = MockWebSocketTransport()
        let session = BailianStreamingSession(
            configuration: try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace"),
            transport: transport, healthStore: health, sendTimeout: .milliseconds(50)
        )
        try await session.connect(apiKey: "test", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        await transport.blockSend()
        do { try await session.sendAudio(Data([1, 2])); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? BailianError, .timeout) }
        let closed = await transport.closed()
        XCTAssertTrue(closed)
        try await health.ensureAttemptAllowed()
    }

    func testBlockedFinishTaskTimesOutRatherThanHangingFinalization() async throws {
        let transport = MockWebSocketTransport()
        let session = BailianStreamingSession(
            configuration: try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace"),
            transport: transport, healthStore: BailianProviderHealthStore(), sendTimeout: .milliseconds(50)
        )
        try await session.connect(apiKey: "test", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        await transport.blockSend()
        do { try await session.requestFinish(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? BailianError, .timeout) }
        let closed = await transport.closed()
        XCTAssertTrue(closed)
    }

    func testStartupDeadlineClosesTransportWhenRunTaskSendIsStuck() async throws {
        let health = BailianProviderHealthStore()
        let (session, transport) = try makeSession(healthStore: health)
        await transport.blockSend()
        let start = ContinuousClock.now
        do {
            try await session.connectAndWaitForStarted(
                apiKey: "test", hints: BailianRecognitionHints(), timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? BailianError, .timeout) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let closed = await transport.closed()
        XCTAssertTrue(closed, "Deadline must release the blocked WebSocket send")
        try await health.ensureAttemptAllowed()
    }

    func testStartupDeadlineIncludesMissingTaskStartedAcknowledgement() async throws {
        let (session, transport) = try makeSession()
        do {
            try await session.connectAndWaitForStarted(
                apiKey: "test", hints: BailianRecognitionHints(), timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? BailianError, .timeout) }
        let closed = await transport.closed()
        XCTAssertTrue(closed)
    }

    func testCancelDuringBlockedStartupReleasesSendImmediately() async throws {
        let (session, transport) = try makeSession()
        await transport.blockSend()
        let startup = Task {
            try await session.connectAndWaitForStarted(apiKey: "test", hints: BailianRecognitionHints())
        }
        _ = try await waitForTaskID(from: transport)
        startup.cancel()
        do { try await startup.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? BailianError, .canceled) }
        let closed = await transport.closed()
        XCTAssertTrue(closed)
    }

    func testStartedAcknowledgementCompletesStartupWithoutConsumingOutputs() async throws {
        let (session, transport) = try makeSession()
        let startup = Task {
            try await session.connectAndWaitForStarted(apiKey: "test", hints: BailianRecognitionHints())
        }
        let taskID = try await waitForTaskID(from: transport)
        await transport.push(.text(started(taskID)))
        try await startup.value
        var iterator = session.outputs.makeAsyncIterator()
        let output = await iterator.next()
        XCTAssertEqual(output, .sessionStarted)
        await session.cancel()
    }

    private func makeSession(healthStore: BailianProviderHealthStore = BailianProviderHealthStore()) throws -> (BailianStreamingSession, MockWebSocketTransport) {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
        let transport = MockWebSocketTransport()
        return (
            BailianStreamingSession(
                configuration: configuration,
                transport: transport,
                healthStore: healthStore
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

    private func waitForTaskID(from transport: MockWebSocketTransport) async throws -> String {
        for _ in 0..<100 {
            if !(await transport.sentMessages()).isEmpty {
                return try await taskID(from: transport)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw BailianError.timeout
    }

    private func waitForFinishTask(from transport: MockWebSocketTransport) async throws {
        for _ in 0..<500 {
            let messages = await transport.sentMessages()
            if messages.contains(where: {
                guard case .text(let text) = $0 else { return false }
                return text.contains("finish-task")
            }) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw BailianError.timeout
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
        try await waitForFinishTask(from: transport)
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
            XCTAssertEqual(error, .protocolViolation("result-generated 早于 task-started"))
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
        try await waitForFinishTask(from: transport)
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
        try await waitForFinishTask(from: transport)
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
        do {
            try await session.sendAudio(Data([1]))
            XCTFail("Expected original credential error")
        } catch let error as BailianError {
            XCTAssertEqual(error, .invalidCredential(statusCode: 401))
        }
        let healthAfterLateAudio = await healthStore.health
        XCTAssertEqual(healthAfterLateAudio, .invalidCredential)
    }

    func testSessionFailureAllowsNewStreamingSessionWithoutReset() async throws {
        for failureKind in ["noWords", "protocol", "disconnect"] {
            let store = BailianProviderHealthStore()
            let (session, transport) = try makeSession(healthStore: store)
            try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
            let id = try await taskID(from: transport)
            await session.handleServerText(started(id))
            var outputs = session.outputs.makeAsyncIterator()
            _ = await outputs.next()
            switch failureKind {
            case "noWords":
                await session.handleServerText(failed(id, code: "CLIENT_ERROR", message: "ASR_RESPONSE_HAVE_NO_WORDS"))
            case "protocol":
                await session.handleServerText(started(id))
            default:
                await transport.failReceive(BailianErrorMapper.mapWebSocketFailure(
                    statusCode: 101, underlyingError: URLError(.networkConnectionLost)
                ))
            }
            let output = await outputs.next()
            guard case .failed(let original) = output else {
                XCTFail("Expected terminal failure")
                return
            }
            for _ in 0..<3 {
                do {
                    try await session.sendAudio(Data([1]))
                    XCTFail("Failed session must reject late audio")
                } catch let error as BailianError {
                    XCTAssertEqual(error, original)
                }
            }
            try await store.ensureAttemptAllowed()
            let (next, nextTransport) = try makeSession(healthStore: store)
            try await next.connect(apiKey: "secret", hints: BailianRecognitionHints())
            let nextID = try await taskID(from: nextTransport)
            await next.handleServerText(started(nextID))
            try await next.sendAudio(Data([2]))
            await next.handleServerText(result(nextID, id: 1, text: "恢复", isFinal: true))
            try await next.requestFinish()
            await next.handleServerText(finished(nextID))
            var nextOutputs = next.outputs.makeAsyncIterator()
            var finalText: String?
            while let output = await nextOutputs.next() {
                if case .final(let text) = output { finalText = text }
            }
            XCTAssertEqual(finalText, "恢复")
        }
    }

    func testEmptyStreamThenNoWordsBatchDoesNotLockNextStreamingRequest() async throws {
        try await assertEmptyStreamThenBatchAllowsNextStreamingRequest(
            body: #"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS"}"#, expected: .emptyFinal
        )
    }

    func testEmptyStreamThenRealEmpty400BodyAllowsNextStreamingRequest() async throws {
        try await assertEmptyStreamThenBatchAllowsNextStreamingRequest(
            body: "{}", expected: .requestRejected(statusCode: 400)
        )
    }

    private func assertEmptyStreamThenBatchAllowsNextStreamingRequest(body: String, expected: BailianError) async throws {
        let store = BailianProviderHealthStore()
        let (silent, silentTransport) = try makeSession(healthStore: store)
        try await silent.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let silentID = try await taskID(from: silentTransport)
        await silent.handleServerText(started(silentID))
        try await silent.requestFinish()
        await silent.handleServerText(finished(silentID))
        var outputs = silent.outputs.makeAsyncIterator()
        _ = await outputs.next()
        let emptyStream = await outputs.next()
        XCTAssertEqual(emptyStream, .failed(.emptyFinal))

        let batch = BailianBatchClient(
            configuration: try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace"),
            transport: NoWordsHTTPTransport(json: body), healthStore: store
        )
        do {
            _ = try await batch.transcribe(
                audioData: Data([0]), fileName: "silent.wav", apiKey: "secret",
                hints: BailianRecognitionHints(), timeout: 1
            )
            XCTFail("Expected batch no words")
        } catch let error as BailianError {
            XCTAssertEqual(error, expected)
        }

        // Reuse the same health store, with no reset, saved key/configuration, or restart.
        let (next, transport) = try makeSession(healthStore: store)
        try await next.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await next.handleServerText(started(id))
        try await next.sendAudio(Data([1]))
        await next.handleServerText(result(id, id: 1, text: "下一次正常识别", isFinal: true))
        try await next.requestFinish()
        await next.handleServerText(finished(id))
        var nextOutputs = next.outputs.makeAsyncIterator()
        _ = await nextOutputs.next()
        _ = await nextOutputs.next()
        let recovered = await nextOutputs.next()
        XCTAssertEqual(recovered, .final("下一次正常识别"))
    }

    func testLateAudioDuringFinalizationDoesNotFailHealthySession() async throws {
        let store = BailianProviderHealthStore()
        let (session, transport) = try makeSession(healthStore: store)
        try await session.connect(apiKey: "secret", hints: BailianRecognitionHints())
        let id = try await taskID(from: transport)
        await session.handleServerText(started(id))
        await session.handleServerText(result(id, id: 1, text: "完整结果", isFinal: true))
        try await session.requestFinish()
        do {
            try await session.sendAudio(Data([1]))
            XCTFail("Finalizing session must reject late audio")
        } catch let error as BailianError {
            XCTAssertEqual(error, .disconnected)
        }
        let health = await store.health
        XCTAssertEqual(health, .healthy)
        await session.handleServerText(finished(id))
        var outputs = session.outputs.makeAsyncIterator()
        _ = await outputs.next()
        _ = await outputs.next()
        let final = await outputs.next()
        XCTAssertEqual(final, .final("完整结果"))
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

    func testConnectionVerificationStopsAfterTaskStartedWithoutSendingAudio() async throws {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
        let transport = MockWebSocketTransport()
        let healthStore = BailianProviderHealthStore()
        let verification = Task {
            await BailianProvider().verifyAPIKey(
                "secret",
                configuration: configuration,
                transport: transport,
                healthStore: healthStore,
                timeout: .seconds(1)
            )
        }

        let id = try await waitForTaskID(from: transport)
        await transport.push(.text(started(id)))
        let result = await verification.value

        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.errorMessage)
        let isClosed = await transport.closed()
        XCTAssertTrue(isClosed)
        let messages = await transport.sentMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages.allSatisfy { message in
            guard case .text(let text) = message else { return false }
            return text.contains("run-task")
        })
    }

    func testConnectionVerificationReturnsSanitizedTaskFailureAndCloses() async throws {
        let configuration = try BailianConfiguration(region: .chinaNorth2, workspaceID: "workspace")
        let transport = MockWebSocketTransport()
        let healthStore = BailianProviderHealthStore()
        let verification = Task {
            await BailianProvider().verifyAPIKey(
                "secret",
                configuration: configuration,
                transport: transport,
                healthStore: healthStore,
                timeout: .seconds(1)
            )
        }

        let id = try await waitForTaskID(from: transport)
        await transport.push(.text(failed(id, code: "AUTHENTICATION_FAILED", message: "raw secret detail")))
        let result = await verification.value

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errorMessage, "百炼 API Key 无效或无权访问当前地域/业务空间")
        XCTAssertFalse(result.errorMessage?.contains("raw secret detail") == true)
        let isClosed = await transport.closed()
        let health = await healthStore.health
        XCTAssertTrue(isClosed)
        XCTAssertEqual(health, .invalidCredential)
    }
}
