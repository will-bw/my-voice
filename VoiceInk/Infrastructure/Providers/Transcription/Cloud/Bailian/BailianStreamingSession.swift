import Foundation

enum BailianStreamingOutput: Equatable, Sendable {
    case sessionStarted
    case partial(String)
    case committed(String)
    case final(String)
    case failed(BailianError)
}

private struct BailianServerEnvelope: Decodable {
    struct Header: Decodable {
        let taskID: String?
        let event: String
        let errorCode: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case event
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    struct Payload: Decodable {
        struct Output: Decodable {
            struct Sentence: Decodable {
                let text: String?
                let heartbeat: Bool?
                let sentenceEnd: Bool?
                let sentenceID: Int?

                enum CodingKeys: String, CodingKey {
                    case text, heartbeat
                    case sentenceEnd = "sentence_end"
                    case sentenceID = "sentence_id"
                }
            }
            let sentence: Sentence?
        }
        let output: Output?
    }

    let header: Header
    let payload: Payload?
}

actor BailianStreamingSession {
    private enum State: Equatable {
        case idle
        case connecting
        case streaming
        case finalizing
        case finished
        case canceled
        case failed
    }

    private let configuration: BailianConfiguration
    private let transport: any BailianWebSocketTransport
    private let healthStore: BailianProviderHealthStore
    private let decoder = JSONDecoder()
    private var state: State = .idle
    private var taskID = ""
    private var committedSentences: [Int: String] = [:]
    private var partialSentences: [Int: String] = [:]
    private var receiveTask: Task<Void, Never>?
    private var outputContinuation: AsyncStream<BailianStreamingOutput>.Continuation?
    nonisolated let outputs: AsyncStream<BailianStreamingOutput>

    init(
        configuration: BailianConfiguration,
        transport: any BailianWebSocketTransport,
        healthStore: BailianProviderHealthStore = BailianProviderHealthStore()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.healthStore = healthStore
        var continuation: AsyncStream<BailianStreamingOutput>.Continuation!
        outputs = AsyncStream { continuation = $0 }
        outputContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        outputContinuation?.finish()
    }

    func connect(apiKey: String, hints: BailianRecognitionHints) async throws {
        guard state == .idle else { throw BailianError.protocolViolation("会话已启动") }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BailianError.missingAPIKey
        }

        state = .connecting
        taskID = UUID().uuidString.lowercased()
        var request = URLRequest(url: configuration.webSocketEndpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("my-voice/1", forHTTPHeaderField: "User-Agent")

        do {
            try await transport.connect(request: request)
            try await transport.send(.text(try makeRunTaskJSON(hints: hints)))
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            let mapped = BailianErrorMapper.map(error)
            state = .failed
            await healthStore.record(mapped)
            throw mapped
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard state == .streaming else {
            throw BailianError.protocolViolation("收到 task-started 前不能发送音频")
        }
        do {
            try await transport.send(.data(data))
        } catch {
            throw await fail(BailianErrorMapper.map(error))
        }
    }

    func finish(timeout: Duration = .seconds(15)) async throws -> String {
        try await requestFinish()

        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { [outputs] in
                    for await output in outputs {
                        switch output {
                        case .final(let text): return text
                        case .failed(let error): throw error
                        default: continue
                        }
                    }
                    throw BailianError.disconnected
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw BailianError.timeout
                }
                guard let result = try await group.next() else { throw BailianError.disconnected }
                group.cancelAll()
                return result
            }
        } catch {
            throw await fail(BailianErrorMapper.map(error))
        }
    }

    func requestFinish() async throws {
        guard state == .streaming else {
            throw BailianError.protocolViolation("当前会话不能结束")
        }
        state = .finalizing
        do {
            try await transport.send(.text(try makeFinishTaskJSON()))
        } catch {
            throw await fail(BailianErrorMapper.map(error))
        }
    }

    func cancel() async {
        guard state != .canceled, state != .finished else { return }
        state = .canceled
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        outputContinuation?.finish()
    }

    func handleServerText(_ text: String) async {
        guard state != .canceled, state != .finished, state != .failed else { return }
        do {
            let envelope = try decoder.decode(BailianServerEnvelope.self, from: Data(text.utf8))
            if let eventTaskID = envelope.header.taskID, eventTaskID != taskID {
                throw BailianError.protocolViolation("事件 task_id 不匹配")
            }
            switch envelope.header.event {
            case "task-started":
                guard state == .connecting else {
                    throw BailianError.protocolViolation("task-started 乱序或重复")
                }
                state = .streaming
                await healthStore.markHealthy()
                outputContinuation?.yield(.sessionStarted)

            case "result-generated":
                guard state == .streaming || state == .finalizing else {
                    throw BailianError.protocolViolation("result-generated 早于 task-started")
                }
                guard let sentence = envelope.payload?.output?.sentence else {
                    throw BailianError.invalidResponse("缺少 sentence")
                }
                if sentence.heartbeat == true { return }
                guard let sentenceID = sentence.sentenceID, sentenceID > 0 else {
                    throw BailianError.invalidResponse("sentence_id 无效")
                }
                let sentenceText = (sentence.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.sentenceEnd == true {
                    partialSentences.removeValue(forKey: sentenceID)
                    if !sentenceText.isEmpty { committedSentences[sentenceID] = sentenceText }
                    outputContinuation?.yield(.committed(assembledText()))
                } else {
                    partialSentences[sentenceID] = sentenceText
                    outputContinuation?.yield(.partial(assembledText(includingPartials: true)))
                }

            case "task-finished":
                guard state == .finalizing else {
                    throw BailianError.protocolViolation("task-finished 早于 finish-task")
                }
                let final = assembledText()
                guard !final.isEmpty else { throw BailianError.emptyFinal }
                state = .finished
                await healthStore.markHealthy()
                outputContinuation?.yield(.final(final))
                outputContinuation?.finish()
                await transport.close()

            case "task-failed":
                throw BailianErrorMapper.mapTaskFailure(
                    code: envelope.header.errorCode,
                    message: envelope.header.errorMessage
                )

            default:
                return
            }
        } catch {
            _ = await fail(BailianErrorMapper.map(error))
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                switch try await transport.receive() {
                case .text(let text): await handleServerText(text)
                case .data: continue
                }
            } catch {
                if Task.isCancelled { return }
                _ = await fail(BailianErrorMapper.map(error))
                return
            }
        }
    }

    @discardableResult
    private func fail(_ error: BailianError) async -> BailianError {
        guard state != .canceled, state != .finished, state != .failed else { return error }
        state = .failed
        receiveTask?.cancel()
        await healthStore.record(error)
        outputContinuation?.yield(.failed(error))
        outputContinuation?.finish()
        await transport.close()
        return error
    }

    private func assembledText(includingPartials: Bool = false) -> String {
        var all = committedSentences
        if includingPartials {
            for (id, text) in partialSentences where all[id] == nil { all[id] = text }
        }
        return all.keys.sorted().compactMap { all[$0] }.filter { !$0.isEmpty }.joined()
    }

    private func makeRunTaskJSON(hints: BailianRecognitionHints) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "semantic_punctuation_enabled": false,
        ]
        if !hints.vocabulary.isEmpty { parameters["vocabulary"] = hints.vocabulary }
        if !hints.languageHints.isEmpty { parameters["language_hints"] = hints.languageHints }

        var input: [String: Any] = [:]
        if let context = hints.context {
            input["context"] = [[
                "role": "user",
                "content": [["type": "input_text", "text": context]],
            ]]
        }
        let body: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": BailianConfiguration.streamingModel,
                "parameters": parameters,
                "input": input,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeFinishTaskJSON() throws -> String {
        let body: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [:] as [String: Any]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
