import Foundation
import OSLog

/// kap-server REST 客户端。
///
/// 所有响应都过统一信封（`{code,msg,data,request_id}`），`code != 0` 转成 `KapError.api`。
/// 鉴权是一个闭包而不是固定字符串：relay 用的 refresh token 会被刷新替换，
/// 每次请求都重新取，避免握着过期的那份。
struct KapClient: Sendable {
    let endpoint: Endpoint
    let tokenProvider: @Sendable () async -> String?

    private static let logger = Logger(subsystem: "com.qinkun.kimicode", category: "rest")

    private var session: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    // MARK: 元信息

    func meta() async throws -> ServerMeta {
        try await get("meta")
    }

    // MARK: 会话

    func sessions(pageSize: Int = 100) async throws -> SessionList {
        try await get("sessions", query: ["page_size": String(pageSize)])
    }

    func workspaces() async throws -> [Workspace] {
        let list: WorkspaceList = try await get("workspaces")
        return list.items
    }

    func models() async throws -> [ModelInfo] {
        let list: ModelList = try await get("models")
        return list.items
    }

    func configDefaults() async throws -> ServerConfigDefaults {
        try await get("config")
    }

    /// 订阅用量。是那台电脑上登录的账号的用量（与本 App 同账号）。
    func usage() async throws -> PlanUsage {
        try await get("oauth/usage")
    }

    /// 那台电脑上登录的 Kimi 账号（与本 App 同账号）的昵称和头像。
    func userInfo() async throws -> KimiUser? {
        let response: UserInfoResponse = try await get("oauth/userinfo")
        return response.userInfo
    }

    func session(_ id: String) async throws -> SessionSummary {
        try await get("sessions/\(id)")
    }

    func status(_ sessionID: String) async throws -> SessionRuntimeStatus {
        try await get("sessions/\(sessionID)/status")
    }

    /// 改会话的模型 / 思考强度 / 权限模式。
    @discardableResult
    func updateProfile(_ sessionID: String, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        struct Body: Encodable {
            let agentConfig: AgentConfigPatch
            enum CodingKeys: String, CodingKey { case agentConfig = "agent_config" }
        }
        return try await post("sessions/\(sessionID)/profile", body: Body(agentConfig: agentConfig))
    }

    func history(_ sessionID: String, pageSize: Int = 200, beforeTurn: String? = nil) async throws -> HistoryPage {
        var query = ["page_size": String(pageSize)]
        if let beforeTurn { query["before_turn"] = beforeTurn }
        return try await get("sessions/\(sessionID)/history", query: query)
    }

    /// 在某个工作区里新建会话。与网页端 `createSession` 同形：`{ metadata:{cwd}, workspace_id, agent_config }`。
    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        struct Body: Encodable {
            let metadata: Metadata
            let workspaceID: String
            let agentConfig: AgentConfigPatch
            struct Metadata: Encodable { let cwd: String }
            enum CodingKeys: String, CodingKey {
                case metadata
                case workspaceID = "workspace_id"
                case agentConfig = "agent_config"
            }
        }
        return try await post(
            "sessions",
            body: Body(metadata: .init(cwd: workspace.root), workspaceID: workspace.id, agentConfig: agentConfig)
        )
    }

    // MARK: 发任务 / 打断

    /// 发任务。会话忙时服务端会把它排队（`status: "queued"`），与网页端一致。
    /// 注意 `prompts:steer` 的入参是 `{prompt_ids}`（把已排队的提前插入），不是文本。
    func sendPrompt(_ body: PromptBody, to sessionID: String) async throws -> PromptAccepted {
        try await post("sessions/\(sessionID)/prompts", body: body)
    }

    /// 上传附件：multipart `file` + `name`，与网页端 `uploadFile` 一致。
    /// 走隧道的 HTTP 单请求上限 10 MiB，调用方先挡掉过大的文件。
    func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> UploadedFile {
        let boundary = "kimi-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
        append("Content-Type: \(mediaType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint.apiBaseURL.appending(path: "files"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        let (responseData, response) = try await session.upload(for: request, from: body)
        return try decodeEnvelope(responseData, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: "files")
    }

    /// 停止当前 turn（网页端的停止按钮走的就是它）。
    func abort(_ sessionID: String) async throws {
        struct Empty: Encodable {}
        let _: JSONValue = try await post("sessions/\(sessionID):abort", body: Empty())
    }

    // MARK: 权限确认

    func pendingApprovals(_ sessionID: String) async throws -> ApprovalList {
        try await get("sessions/\(sessionID)/approvals", query: ["status": "pending"])
    }

    /// 返回 false 表示这条已被别处（比如电脑上的 TUI）处理过了。
    func resolve(
        approval approvalID: String,
        in sessionID: String,
        with decision: ApprovalDecisionBody
    ) async throws -> Bool {
        do {
            let result: ApprovalResolveResult = try await post(
                "sessions/\(sessionID)/approvals/\(approvalID)",
                body: decision
            )
            return result.resolved
        } catch let KapError.api(code, _) where code == KapErrorCode.approvalAlreadyResolved {
            return false
        }
    }

    // MARK: 底层

    func get<Response: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> Response {
        try await send(method: "GET", path: path, query: query, body: Optional<Never>.none)
    }

    func post<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        try await send(method: "POST", path: path, query: [:], body: body)
    }

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> Response {
        var components = URLComponents(
            url: endpoint.apiBaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw KapError.http(status: 0, body: "无法构造 URL：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: path)
    }

    private func decodeEnvelope<Response: Decodable>(_ data: Data, status: Int, path: String) throws -> Response {
        guard (200 ..< 300).contains(status) else {
            // relay 的错误不是信封格式（`{"error":{"message":…}}`），原样带上去。
            throw KapError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch {
            if let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw KapError.api(code: error.code, message: error.msg)
            }
            Self.logger.error("解码 \(path) 失败：\(error)")
            throw KapError.decoding(underlying: error, context: path)
        }

        guard envelope.code == KapErrorCode.ok, let payload = envelope.data else {
            throw KapError.api(code: envelope.code, message: envelope.msg)
        }
        return payload
    }
}

// MARK: - Relay

/// relay 自身的接口（不经隧道）：目前只有设备列表。
struct RelayClient: Sendable {
    let origin: URL
    let tokenProvider: @Sendable () async -> String?

    func devices() async throws -> RemoteDeviceList {
        var request = URLRequest(url: origin.appending(path: "v1/remote/devices"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw KapError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(RemoteDeviceList.self, from: data)
        } catch {
            throw KapError.decoding(underlying: error, context: "设备列表")
        }
    }
}
