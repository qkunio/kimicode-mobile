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
}

/// kap-server 的 WebSocket 事件通道。
///
/// 设计取向：**把 WS 当作"有什么变了"的信号，权威状态一律回 REST 拿。**
/// 事件 payload 是个很大的联合体（`asyncapi.json` 里 `session_event` 的 payload 有 6 万字符），
/// 把它全部映射成 Swift 类型既脆弱又没必要 —— 没见过的 `type` 会让整条流断掉。
/// 所以这里只严格解码信封（type/seq/epoch/session_id），payload 原样留着，
/// 上层按已知 type 走快路径、未知 type 触发一次 REST 刷新。
///
/// 游标：每条事件的 `seq`+`epoch` 按会话记下来，重连时在 `client_hello.cursors` 里带回去，
/// 服务端用 ack 里的 `resync_required` 告诉我们哪些会话接不上。不带游标重连会错序丢消息。
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

    func unsubscribe(from sessionID: String) async {
        subscribedSessions.remove(sessionID)
        guard task != nil else { return }
        await send([
            "type": .string("unsubscribe"),
            "id": .string(nextMessageID()),
            "payload": .object(["session_ids": .array([.string(sessionID)])]),
        ])
    }

    /// 中断某条会话当前的 turn。
    func abort(sessionID: String) async {
        await send([
            "type": .string("abort"),
            "id": .string(nextMessageID()),
            "payload": .object(["session_id": .string(sessionID)]),
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
