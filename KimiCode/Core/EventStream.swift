import Foundation
import OSLog

/// 服务端推来的事件信封。`payload` 是刻意不定型的联合体，保留原始 JSON。
struct SessionEventFrame: Decodable, Sendable {
    let type: String
    let seq: Int?
    let epoch: String?
    let volatile: Bool?
    let sessionID: String?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type, seq, epoch, volatile, payload
        case sessionID = "session_id"
    }
}

/// WS 连接对外发出的信号。
enum StreamSignal: Sendable {
    case connected(heartbeatMS: Int?)
    case disconnected(reason: String)
    /// 一条会话事件。
    case event(SessionEventFrame)
    /// 这些会话的增量续不上了（服务端 `resync_required`，多半是历史被压缩过），必须全量重拉。
    case resyncRequired([String])
    /// 对话正文的增量（`subscribe_v2` 订阅的 `transcript.reset` / `transcript.ops`）。
    case transcript(sessionID: String, TranscriptWireEvent)
}

/// kap-server 的 WebSocket 事件通道。
///
/// 两类订阅：
///   - `subscribe`：会话事件。payload 是个很大的联合体，只严格解码信封（type/seq/epoch/session_id），
///     上层只拿它当「确认 / 提问有变化」的信号。
///   - `subscribe_v2`：对话正文（transcript）的逐字增量，`transcript.reset / ops` 单独解码后交给上层应用。
///
/// 游标：会话事件按 `seq`+`epoch` 记，重连时放进 `client_hello.cursors`；正文按批次 `seq` 记，
/// 重连时放进 `transcript_since`，服务端补发缺的 ops，补不上就发 reset。
actor EventStream {
    private let endpoint: Endpoint
    private let tokenProvider: @Sendable () async -> String?
    private let clientID: String
    private let logger = Logger(subsystem: "com.qinkun.kimicode", category: "ws")

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pumpTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamSignal>.Continuation?

    /// session_id → 最后看到的 seq/epoch。
    private var cursors: [String: Cursor] = [:]
    private var subscribedSessions: Set<String> = []
    /// session_id → 已应用到的 transcript 批次序号（`transcript_since`）。nil = 还没拿到过。
    private var transcriptSubscriptions: [String: Int?] = [:]
    private var messageSeq = 0
    private var reconnectAttempt = 0
    private var isStopped = false

    private struct Cursor: Encodable {
        let seq: Int
        var epoch: String?
    }

    init(
        endpoint: Endpoint,
        clientID: String = "ios_\(UUID().uuidString.prefix(8))",
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.tokenProvider = tokenProvider
    }

    /// 开始连接，返回信号流。重连由内部自动处理，流不会因为断线而结束。
    func start() -> AsyncStream<StreamSignal> {
        let (stream, continuation) = AsyncStream<StreamSignal>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation
        isStopped = false
        pumpTask = Task { await runLoop() }
        return stream
    }

    func stop() {
        isStopped = true
        pumpTask?.cancel()
        keepAliveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// 订阅一条会话的事件。连接还没建立也可以调用，连上后会自动补发。
    func subscribe(to sessionID: String) async {
        subscribedSessions.insert(sessionID)
        guard task != nil else { return }
        await send([
            "type": .string("subscribe"),
            "id": .string(nextMessageID()),
            "payload": .object([
                "session_ids": .array([.string(sessionID)]),
                "cursors": cursorPayload(for: [sessionID]),
            ]),
        ])
    }

    /// 订阅对话正文的逐字增量（与网页端 `sendTranscriptSubscribe` 一致：`main` 走 `delta` 级别）。
    /// `since` 是已经拿到的批次序号：服务端据此补发缺的 ops，补不上就发一个 `transcript.reset`。
    func subscribeTranscript(_ sessionID: String, since: Int?) async {
        transcriptSubscriptions[sessionID] = since
        guard task != nil else { return }
        await sendTranscriptSubscribe(sessionID)
    }

    /// 上层应用完一批 ops 后回报序号，重连时用。
    func noteTranscriptSeq(_ sessionID: String, seq: Int) {
        guard transcriptSubscriptions[sessionID] != nil else { return }
        transcriptSubscriptions[sessionID] = seq
    }

    private func sendTranscriptSubscribe(_ sessionID: String) async {
        var payload: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "transcript": .object(["main": .string("delta")]),
        ]
        if let since = transcriptSubscriptions[sessionID] ?? nil {
            payload["transcript_since"] = .object(["main": .number(Double(since))])
        }
        await send([
            "type": .string("subscribe_v2"),
            "id": .string(nextMessageID()),
            "payload": .object(payload),
        ])
    }

    func unsubscribe(from sessionID: String) async {
        subscribedSessions.remove(sessionID)
        guard task != nil else { return }
        await send([
            "type": .string("unsubscribe"),
            "id": .string(nextMessageID()),
            "payload": .object(["session_ids": .array([.string(sessionID)])]),
        ])
    }

    // MARK: 连接循环

    private func runLoop() async {
        while !isStopped, !Task.isCancelled {
            do {
                try await connectOnce()
                reconnectAttempt = 0
                // connectOnce 正常返回 = 对端关了连接。
                continuation?.yield(.disconnected(reason: "连接关闭"))
            } catch is CancellationError {
                return
            } catch {
                logger.error("ws 断开：\(error.localizedDescription)")
                continuation?.yield(.disconnected(reason: error.localizedDescription))
            }
            if isStopped || Task.isCancelled { return }
            reconnectAttempt += 1
            // 指数退避，上限 30s —— 与桌面端隧道的退避一致。
            let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt - 1, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func connectOnce() async throws {
        guard let url = endpoint.webSocketURL(clientID: clientID) else {
            throw KapError.http(status: 0, body: "无法构造 WS 地址")
        }
        var request = URLRequest(url: url)
        // relay 接受 Authorization 头（已实测）。浏览器因为不能设 WS 请求头才必须用
        // `kimi-code.bearer.<token>` subprotocol，原生端不需要。
        let token = await tokenProvider()
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()

        defer {
            keepAliveTask?.cancel()
            keepAliveTask = nil
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if self.task === task { self.task = nil }
        }

        // 第一帧必须是 server_hello。
        let hello = try await receiveFrame(on: task)
        guard hello["type"]?.stringValue == "server_hello" else {
            throw KapError.http(status: 0, body: "期待 server_hello，收到 \(hello["type"]?.stringValue ?? "?")")
        }
        let heartbeatMS = hello["payload"]?["heartbeat_ms"]?.intValue
        logger.info("server_hello protocol=\(hello["payload"]?["protocol_version"]?.intValue ?? -1)")

        // client_hello：把已订阅的会话和游标一起带上，服务端会回 ack。
        await send([
            "type": .string("client_hello"),
            "id": .string(nextMessageID()),
            "payload": .object([
                "client_id": .string(clientID),
                "subscriptions": .array(subscribedSessions.map { .string($0) }),
                "cursors": cursorPayload(for: subscribedSessions),
            ]),
        ])

        for sessionID in transcriptSubscriptions.keys {
            await sendTranscriptSubscribe(sessionID)
        }

        continuation?.yield(.connected(heartbeatMS: heartbeatMS))
        startKeepAlive(intervalMS: heartbeatMS ?? 10_000)

        while !isStopped, !Task.isCancelled {
            let frame = try await receiveFrame(on: task)
            handle(frame)
        }
    }

    private func startKeepAlive(intervalMS: Int) {
        keepAliveTask?.cancel()
        // 服务端实测 heartbeat_ms=10000，按它的一半发 ping，别硬编码 30s。
        let interval = Duration.milliseconds(max(2000, intervalMS / 2))
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    private func sendPing() async {
        await send([
            "type": .string("ping"),
            "id": .string(nextMessageID()),
            "payload": .object([:]),
        ])
    }

    // MARK: 收发

    private func receiveFrame(on task: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
        let message = try await task.receive()
        let data: Data = switch message {
        case let .data(payload): payload
        case let .string(text): Data(text.utf8)
        @unknown default: Data()
        }
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            logger.error("ws 帧解析失败：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            return [:]
        }
    }

    private func handle(_ frame: [String: JSONValue]) {
        guard let type = frame["type"]?.stringValue else { return }

        switch type {
        case "pong", "ping":
            return

        case "ack":
            // subscribe / client_hello 的应答。resync_required 说明增量接不上了。
            if let sessions = frame["payload"]?["resync_required"]?.arrayValue?.compactMap(\.stringValue),
               !sessions.isEmpty {
                logger.info("需要重新拉取历史：\(sessions.joined(separator: ","))")
                continuation?.yield(.resyncRequired(sessions))
            }
            if let cursors = frame["payload"]?["cursors"]?.objectValue {
                for (sessionID, cursor) in cursors {
                    if let seq = cursor["seq"]?.intValue {
                        self.cursors[sessionID] = Cursor(seq: seq, epoch: cursor["epoch"]?.stringValue)
                    }
                }
            }
            return

        case "resync_required":
            let sessions = frame["payload"]?["session_ids"]?.arrayValue?.compactMap(\.stringValue)
                ?? frame["session_id"]?.stringValue.map { [$0] }
                ?? []
            continuation?.yield(.resyncRequired(sessions))
            return

        case "transcript.reset", "transcript.ops":
            // 正文增量走专门的解码：payload 里是 camelCase 的 ops，不进通用事件。
            guard
                let sessionID = frame["session_id"]?.stringValue,
                let payload = frame["payload"],
                let data = try? JSONEncoder().encode(payload)
            else { return }
            do {
                let event = try JSONDecoder().decode(TranscriptWireEvent.self, from: data)
                continuation?.yield(.transcript(sessionID: sessionID, event))
            } catch {
                logger.error("transcript 帧解析失败：\(error.localizedDescription)")
                // 解不开就当接不上：让上层全量重拉。
                continuation?.yield(.resyncRequired([sessionID]))
            }
            return

        case "error":
            let message = frame["payload"]?["message"]?.stringValue
                ?? frame["msg"]?.stringValue
                ?? "未知错误"
            logger.error("ws error：\(message)")
            return

        default:
            break
        }

        // 其余都当会话事件。`volatile` 的帧（打字机增量那种）不推进游标。
        guard
            let data = try? JSONEncoder().encode(frame),
            let event = try? JSONDecoder().decode(SessionEventFrame.self, from: data)
        else { return }

        if let sessionID = event.sessionID, let seq = event.seq, event.volatile != true {
            let existing = cursors[sessionID]?.seq ?? -1
            if seq > existing {
                cursors[sessionID] = Cursor(seq: seq, epoch: event.epoch ?? cursors[sessionID]?.epoch)
            }
        }
        continuation?.yield(.event(event))
    }

    private func send(_ payload: [String: JSONValue]) async {
        guard let task else { return }
        guard
            let data = try? JSONEncoder().encode(payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await task.send(.string(text))
        } catch {
            logger.error("ws 发送失败：\(error.localizedDescription)")
        }
    }

    private func cursorPayload(for sessions: some Collection<String>) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for sessionID in sessions {
            guard let cursor = cursors[sessionID] else { continue }
            var entry: [String: JSONValue] = ["seq": .number(Double(cursor.seq))]
            if let epoch = cursor.epoch { entry["epoch"] = .string(epoch) }
            result[sessionID] = .object(entry)
        }
        return .object(result)
    }

    private func nextMessageID() -> String {
        messageSeq += 1
        return "\(clientID)-\(messageSeq)"
    }
}
