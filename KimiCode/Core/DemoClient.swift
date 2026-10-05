import Foundation

/// 体验模式（App Store 审核用）的演示后端：不登录、不连 relay、不连任何电脑，
/// 设备 / 文件夹 / 会话 / 回复全部在本地内存里造。
///
/// 界面上的功能都能走通：和「示例 Agent」聊天、新建会话、打开文件夹、切换设备、重命名/删除会话。
/// 给示例 Agent 发任何消息 xxx，它都会回：
/// 「看起来你输入了『xxx』，很高兴认识你，来和我交流体验吧！」
struct DemoClient: Sendable {
    let deviceID: String

    private var backend: DemoBackend { .shared }

    /// 演示设备：两台在线（可以互相切换），一台离线（置灰不可选）。
    static let devices: [RemoteDevice] = DemoData.decode("""
        [
          {"device_id":"demo-macbook-pro","alias":"Demo-MacBook-Pro","platform":"darwin","status":"online"},
          {"device_id":"demo-mac-studio","alias":"Demo-Mac-Studio","platform":"darwin","status":"online"},
          {"device_id":"demo-old-imac","alias":"Old-iMac","platform":"darwin","status":"offline"}
        ]
        """)
}

extension DemoClient: KapServicing {
    func workspaces() async throws -> [Workspace] {
        await backend.workspaces(deviceID: deviceID)
    }

    func addWorkspace(root: String) async throws -> Workspace {
        await backend.addWorkspace(deviceID: deviceID, root: root)
    }

    func browseFs(_ path: String) async throws -> FsBrowse {
        await backend.browseFs(path: path)
    }

    func fsHome() async throws -> FsHome {
        DemoData.fsHome
    }

    func sessions(pageSize _: Int) async throws -> SessionList {
        await backend.sessions(deviceID: deviceID)
    }

    func models() async throws -> [ModelInfo] { DemoData.models }

    func configDefaults() async throws -> ServerConfigDefaults { DemoData.configDefaults }

    func usage() async throws -> PlanUsage { DemoData.usage }

    func userInfo() async throws -> KimiUser? { DemoData.user }

    func status(_ sessionID: String) async throws -> SessionRuntimeStatus {
        await backend.status(deviceID: deviceID, sessionID: sessionID)
    }

    @discardableResult
    func updateProfile(_ sessionID: String, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        try await backend.updateProfile(deviceID: deviceID, sessionID: sessionID, patch: agentConfig)
    }

    @discardableResult
    func renameSession(_ sessionID: String, title: String) async throws -> SessionSummary {
        try await backend.renameSession(deviceID: deviceID, sessionID: sessionID, title: title)
    }

    func deleteSession(_ sessionID: String) async throws {
        await backend.deleteSession(deviceID: deviceID, sessionID: sessionID)
    }

    func transcript(_ sessionID: String, pageSize _: Int, beforeTurn _: String?) async throws -> TranscriptPage {
        await backend.transcript(deviceID: deviceID, sessionID: sessionID)
    }

    func undo(_ sessionID: String, count: Int) async throws {
        await backend.undo(deviceID: deviceID, sessionID: sessionID, count: count)
    }

    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        await backend.createSession(deviceID: deviceID, workspace: workspace, agentConfig: agentConfig)
    }

    func sendPrompt(_ body: PromptBody, to sessionID: String) async throws -> PromptAccepted {
        await backend.sendPrompt(deviceID: deviceID, sessionID: sessionID, body: body)
    }

    func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> UploadedFile {
        UploadedFile(id: "demo-file-\(UUID().uuidString)", name: name, mediaType: mediaType, size: data.count)
    }

    func abort(_ sessionID: String) async throws {
        await backend.abort(deviceID: deviceID, sessionID: sessionID)
    }

    func pendingApprovals(_: String) async throws -> ApprovalList {
        ApprovalList(items: [])
    }

    func resolve(approval _: String, in _: String, with _: ApprovalDecisionBody) async throws -> Bool {
        true
    }

    func pendingQuestions(_: String) async throws -> QuestionList {
        QuestionList(items: [])
    }

    func answer(question _: String, in _: String, with _: QuestionAnswerBody) async throws -> Bool {
        true
    }

    func dismiss(question _: String, in _: String) async throws {}
}

// MARK: - 内存状态

/// 演示后端的状态：按设备分开存，切走再切回来数据还在。整个 App 生命周期共享一份。
private actor DemoBackend {
    static let shared = DemoBackend()

    fileprivate struct Profile {
        var model: String?
        var thinking: String?
        var permission: PermissionMode
    }

    /// 一轮对话：prompt + 若干 frame（frame 是拼好的 JSON 片段，transcript 页也是现拼现解码）。
    fileprivate struct DemoTurn {
        let turnID: String
        var prompt: String
        var state: String
        var startedAt: Date
        var endedAt: Date?
        var frames: [String] = []
    }

    private struct SessionData {
        var profile: Profile
        var turns: [DemoTurn] = []
        /// 已收到、还没到点出现的回复：`readyAt` 之前这一轮是 running，到点后落完。
        var replyReadyAt: Date?
        var seq = 1
    }

    private struct DeviceState {
        var workspaces: [Workspace]
        var sessions: [SessionSummary]
        var data: [String: SessionData] = [:]
    }

    private var states: [String: DeviceState] = [:]

    /// 回复延迟这么久出现，让「正在执行…」有机会露出来。
    private static let replyDelay: TimeInterval = 1.2

    // MARK: 侧栏

    func workspaces(deviceID: String) -> [Workspace] {
        state(for: deviceID).workspaces
    }

    func addWorkspace(deviceID: String, root: String) -> Workspace {
        var state = state(for: deviceID)
        let workspace = DemoData.workspace(
            id: "demo-ws-\(root.hashValue.magnitude)",
            root: root,
            name: nil,
            lastOpenedAt: Date()
        )
        if !state.workspaces.contains(where: { $0.root == root }) {
            state.workspaces.insert(workspace, at: 0)
        }
        states[deviceID] = state
        return state.workspaces.first { $0.root == root } ?? workspace
    }

    /// 假的文件树：`/Users/demo` 下 Projects / Documents，各装两个文件夹。
    func browseFs(path: String) -> FsBrowse {
        let tree: [String: [String]] = [
            "/Users/demo": ["Projects", "Documents"],
            "/Users/demo/Projects": ["sample-project", "my-first-app"],
            "/Users/demo/Documents": ["notes", "archive"],
        ]
        let children = (tree[path] ?? []).map {
            #"{"name":\#(DemoData.quoted($0)),"path":\#(DemoData.quoted("\(path)/\($0)")),"is_dir":true}"#
        }
        let parent = path == DemoData.home ? "null" : DemoData.quoted(DemoData.home)
        return DemoData.decode("""
            {"path":\(DemoData.quoted(path)),"parent":\(parent),"entries":[\(children.joined(separator: ","))]}
            """)
    }

    func sessions(deviceID: String) -> SessionList {
        SessionList(items: state(for: deviceID).sessions, hasMore: false)
    }

    // MARK: 会话

    func transcript(deviceID: String, sessionID: String) -> TranscriptPage {
        materializeReply(deviceID: deviceID, sessionID: sessionID)
        guard let state = states[deviceID], let data = state.data[sessionID] else {
            return DemoData.page(items: [], meta: DemoData.meta(activity: "idle", profile: nil, tokens: 0), seq: 0)
        }
        return DemoData.page(
            items: data.turns.map(DemoData.render),
            meta: DemoData.meta(
                activity: data.replyReadyAt != nil ? "turn" : "idle",
                profile: data.profile,
                tokens: 1_200 + data.turns.count * 800
            ),
            seq: data.seq
        )
    }

    func status(deviceID: String, sessionID: String) -> SessionRuntimeStatus {
        materializeReply(deviceID: deviceID, sessionID: sessionID)
        let data = states[deviceID]?.data[sessionID]
        let profile = data?.profile
            ?? Profile(model: DemoData.configDefaults.defaultModel, thinking: "low", permission: .auto)
        let busy = data?.replyReadyAt != nil
        let contextTokens = min(1_200 + (data?.turns.count ?? 0) * 800, 200_000)
        return DemoData.decode("""
            {"busy":\(busy),"model":\(DemoData.quoted(profile.model ?? "kimi-code/k3")),\
            "thinking_level":\(DemoData.quoted(profile.thinking ?? "low")),\
            "permission":\(DemoData.quoted(profile.permission.rawValue)),\
            "context_tokens":\(contextTokens),"max_context_tokens":262144,\
            "context_usage":\(Double(contextTokens) / 262144)}
            """)
    }

    func createSession(deviceID: String, workspace: Workspace, agentConfig: AgentConfigPatch) -> SessionSummary {
        var state = state(for: deviceID)
        let session = DemoData.session(
            id: "demo-session-\(UUID().uuidString.prefix(8).lowercased())",
            workspaceID: workspace.id,
            title: nil,
            lastPrompt: nil,
            cwd: workspace.root,
            at: Date()
        )
        state.sessions.insert(session, at: 0)
        state.data[session.id] = SessionData(
            profile: Profile(
                model: agentConfig.model,
                thinking: agentConfig.thinking,
                permission: agentConfig.permissionMode ?? .auto
            )
        )
        states[deviceID] = state
        return session
    }

    func updateProfile(deviceID: String, sessionID: String, patch: AgentConfigPatch) throws -> SessionSummary {
        var state = state(for: deviceID)
        guard var data = state.data[sessionID] else { throw KapError.api(code: -1, message: "会话不存在") }
        if let model = patch.model { data.profile.model = model }
        if let thinking = patch.thinking { data.profile.thinking = thinking }
        if let permission = patch.permissionMode { data.profile.permission = permission }
        state.data[sessionID] = data
        states[deviceID] = state
        guard let session = state.sessions.first(where: { $0.id == sessionID }) else {
            throw KapError.api(code: -1, message: "会话不存在")
        }
        return session
    }

    func renameSession(deviceID: String, sessionID: String, title: String) throws -> SessionSummary {
        var state = state(for: deviceID)
        guard let index = state.sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw KapError.api(code: -1, message: "会话不存在")
        }
        let old = state.sessions[index]
        let renamed = DemoData.session(
            id: old.id, workspaceID: old.workspaceID ?? "", title: title,
            lastPrompt: old.lastPrompt, cwd: old.metadata?.cwd ?? "",
            at: old.createdAt?.date ?? Date()
        )
        state.sessions[index] = renamed
        states[deviceID] = state
        return renamed
    }

    func deleteSession(deviceID: String, sessionID: String) {
        var state = state(for: deviceID)
        state.sessions.removeAll { $0.id == sessionID }
        state.data[sessionID] = nil
        states[deviceID] = state
    }

    func sendPrompt(deviceID: String, sessionID: String, body: PromptBody) -> PromptAccepted {
        var state = state(for: deviceID)
        guard var data = state.data[sessionID] else {
            return DemoData.decode(#"{"prompt_id":"\#(UUID().uuidString)","status":"accepted"}"#)
        }
        let text = body.content.compactMap { part -> String? in
            if case let .text(value) = part { return value }
            return nil
        }.joined(separator: "\n")
        let display = text.isEmpty ? "［附件］" : text
        // 消息里带的配置就是这一轮用的配置（与网页端 submitPrompt 一致）。
        if let model = body.model { data.profile.model = model }
        if let thinking = body.thinking { data.profile.thinking = thinking }
        if let permission = body.permissionMode { data.profile.permission = permission }

        let ordinal = data.turns.count + 1
        data.turns.append(DemoTurn(
            turnID: "t_\(ordinal)",
            prompt: display,
            state: "running",
            startedAt: Date()
        ))
        data.replyReadyAt = Date().addingTimeInterval(Self.replyDelay)
        data.seq += 1
        state.data[sessionID] = data

        // 侧栏标题跟着最后一条 prompt 走（与真机的 displayTitle 规则一致）。
        if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) {
            let old = state.sessions[index]
            state.sessions[index] = DemoData.session(
                id: old.id, workspaceID: old.workspaceID ?? "", title: old.title,
                lastPrompt: display, cwd: old.metadata?.cwd ?? "",
                at: old.createdAt?.date ?? Date()
            )
        }
        states[deviceID] = state
        return DemoData.decode("""
            {"prompt_id":"\(UUID().uuidString)","status":"accepted"}
            """)
    }

    func undo(deviceID: String, sessionID: String, count: Int) {
        var state = state(for: deviceID)
        guard var data = state.data[sessionID] else { return }
        // 演示模式每轮都是用户消息：从尾部抹掉 count 轮即可。
        data.turns.removeLast(min(count, data.turns.count))
        data.replyReadyAt = nil
        data.seq += 1
        state.data[sessionID] = data
        states[deviceID] = state
    }

    func abort(deviceID: String, sessionID: String) {
        var state = state(for: deviceID)
        guard var data = state.data[sessionID], data.replyReadyAt != nil else { return }
        if let last = data.turns.indices.last, data.turns[last].state == "running" {
            data.turns[last].state = "cancelled"
            data.turns[last].endedAt = Date()
        }
        data.replyReadyAt = nil
        data.seq += 1
        state.data[sessionID] = data
        states[deviceID] = state
    }

    // MARK: 回复落地

    /// 到点的回复把 running 的那一轮补完：思考 + 正文，turn 完成。
    private func materializeReply(deviceID: String, sessionID: String) {
        guard var state = states[deviceID],
              var data = state.data[sessionID],
              let readyAt = data.replyReadyAt,
              Date() >= readyAt,
              let index = data.turns.indices.last,
              data.turns[index].state == "running" else { return }
        let text = data.turns[index].prompt
        let turnID = data.turns[index].turnID
        let now = Date()
        data.turns[index].frames = [
            DemoData.thinkingFrame(
                id: "\(turnID).f1",
                text: "对方在体验模式里说了「\(text)」。这里没有真正的模型在背后，我只需要友好地回应。"
            ),
            DemoData.textFrame(
                id: "\(turnID).f2",
                text: "看起来你输入了「\(text)」，很高兴认识你，来和我交流体验吧！"
            ),
        ]
        data.turns[index].state = "completed"
        data.turns[index].endedAt = now
        data.replyReadyAt = nil
        data.seq += 1
        state.data[sessionID] = data
        states[deviceID] = state
    }

    // MARK: 播种

    private func state(for deviceID: String) -> DeviceState {
        if let existing = states[deviceID] { return existing }
        let seeded = Self.seed(deviceID: deviceID)
        states[deviceID] = seeded
        return seeded
    }

    private static func seed(deviceID: String) -> DeviceState {
        let now = Date()
        let defaultProfile = Profile(
            model: DemoData.configDefaults.defaultModel, thinking: "low", permission: .auto
        )

        /// 一轮已完成的对话：prompt + 给定的 frame 列表。
        func turn(_ ordinal: Int, _ prompt: String, _ frames: [String], at date: Date) -> DemoTurn {
            DemoTurn(
                turnID: "t_\(ordinal)", prompt: prompt, state: "completed",
                startedAt: date, endedAt: date.addingTimeInterval(6), frames: frames
            )
        }

        switch deviceID {
        case "demo-macbook-pro":
            let sample = DemoData.workspace(
                id: "demo-ws-sample", root: "/Users/demo/Projects/sample-project", name: "示例项目",
                lastOpenedAt: now.addingTimeInterval(-300)
            )
            let app = DemoData.workspace(
                id: "demo-ws-app", root: "/Users/demo/Projects/my-first-app", name: "我的第一个 App",
                lastOpenedAt: now.addingTimeInterval(-7200)
            )
            let intro = DemoData.session(
                id: "demo-session-intro", workspaceID: sample.id, title: "介绍一下这个项目",
                lastPrompt: "帮我看看这个项目是做什么的", cwd: sample.root,
                at: now.addingTimeInterval(-300)
            )
            let copy = DemoData.session(
                id: "demo-session-copy", workspaceID: sample.id, title: "写一版落地页文案",
                lastPrompt: "给这个产品写一版落地页文案", cwd: sample.root,
                at: now.addingTimeInterval(-1800)
            )
            let crash = DemoData.session(
                id: "demo-session-crash", workspaceID: app.id, title: "修复启动崩溃",
                lastPrompt: "App 启动就闪退，帮我查查", cwd: app.root,
                at: now.addingTimeInterval(-7200)
            )
            var state = DeviceState(workspaces: [sample, app], sessions: [intro, copy, crash])
            state.data[intro.id] = SessionData(
                profile: defaultProfile,
                turns: [
                    turn(1, "帮我看看这个项目是做什么的", [
                        DemoData.thinkingFrame(
                            id: "t_1.f1",
                            text: "用户想了解这个项目。我先读一下 README，再看看目录结构。"
                        ),
                        DemoData.toolFrame(
                            id: "t_1.f2", callID: "t_1.c1", name: "read",
                            input: #"{"file_path":"/Users/demo/Projects/sample-project/README.md"}"#,
                            output: "# Sample Project\n\n一个演示用的 iOS 客户端，SwiftUI + Swift 6。"
                        ),
                        DemoData.toolFrame(
                            id: "t_1.f3", callID: "t_1.c2", name: "bash",
                            input: #"{"command":"ls /Users/demo/Projects/sample-project"}"#,
                            output: "README.md\nSources\nTests"
                        ),
                        DemoData.textFrame(
                            id: "t_1.f4",
                            text: "这是一个**演示项目**：一个用 SwiftUI 写的 iOS 客户端。\n\n- `Sources/` 是 App 主体代码\n- `Tests/` 是单元测试\n\n想深入哪一块，跟我说一声就行。"
                        ),
                    ], at: now.addingTimeInterval(-290)),
                ]
            )
            state.data[copy.id] = SessionData(
                profile: defaultProfile,
                turns: [
                    turn(1, "给这个产品写一版落地页文案", [
                        DemoData.textFrame(
                            id: "t_1.f1",
                            text: "主标题：**把 Kimi Code 装进口袋**\n\n副标题：在手机上随时查看进度、批准操作，让 Agent 替你干活。"
                        ),
                    ], at: now.addingTimeInterval(-1790)),
                ]
            )
            state.data[crash.id] = SessionData(
                profile: defaultProfile,
                turns: [
                    turn(1, "App 启动就闪退，帮我查查", [
                        DemoData.textFrame(
                            id: "t_1.f1",
                            text: "看了崩溃日志，是 `AppModel` 在 `init` 里访问了还没初始化的 Keychain。把这次访问挪到首次使用时就好了。"
                        ),
                    ], at: now.addingTimeInterval(-7190)),
                ]
            )
            return state

        case "demo-mac-studio":
            let notes = DemoData.workspace(
                id: "demo-ws-notes", root: "/Users/demo/Documents/notes", name: "工作笔记",
                lastOpenedAt: now.addingTimeInterval(-3600)
            )
            let weekly = DemoData.session(
                id: "demo-session-weekly", workspaceID: notes.id, title: "整理这周的工作笔记",
                lastPrompt: "把这周的笔记整理成一份摘要", cwd: notes.root,
                at: now.addingTimeInterval(-3600)
            )
            var state = DeviceState(workspaces: [notes], sessions: [weekly])
            state.data[weekly.id] = SessionData(
                profile: defaultProfile,
                turns: [
                    turn(1, "把这周的笔记整理成一份摘要", [
                        DemoData.textFrame(
                            id: "t_1.f1",
                            text: "本周要点：\n\n- 完成了登录流程的收尾\n- 演示模式的数据已全部就位\n- 下周准备联调真机"
                        ),
                    ], at: now.addingTimeInterval(-3590)),
                ]
            )
            return state

        default:
            // 离线设备（或未播种的设备）是空壳：不会被选中，给一份空数据兜底。
            return DeviceState(workspaces: [], sessions: [])
        }
    }
}

// MARK: - 静态演示数据

/// 模型 / 用量 / 用户这类全局数据，以及把 JSON 片段变成模型的小工具。
/// 模型类型都是只有 Decodable 的（对齐服务端响应），所以演示数据也用 JSON 解码出来，省得另写一套构造器。
private enum DemoData {
    static func decode<T: Decodable>(_ json: String) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("演示数据 JSON 有误：\(error)\n\(json)")
        }
    }

    /// 把任意字符串转成 JSON 字符串字面量（带引号、已转义），拼 JSON 片段用。
    static func quoted(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static let home = "/Users/demo"

    // MARK: 全局数据

    static let models: [ModelInfo] = decode("""
        [
          {"provider":"managed:kimi-code","model":"kimi-code/k3","display_name":"K3",\
        "max_context_size":262144,"capabilities":["image_in"],\
        "support_efforts":["low","medium","high"],"default_effort":"low"},
          {"provider":"managed:kimi-code","model":"kimi-code/k2.5","display_name":"K2.5",\
        "max_context_size":131072,"capabilities":["image_in"]}
        ]
        """)

    static let configDefaults: ServerConfigDefaults = decode(#"{"default_model":"kimi-code/k3"}"#)

    static let usage: PlanUsage = decode("""
        {"quota":{"usages":{"limit5h":{"usedRatio":0.42},"monthTotal":{"usedRatio":0.63}}}}
        """)

    static let user: KimiUser = decode(#"{"nickname":"体验用户"}"#)

    static let fsHome: FsHome = decode("""
        {"home":"\(home)","recent_roots":[\
        "\(home)/Projects/sample-project",\
        "\(home)/Projects/my-first-app",\
        "\(home)/Documents/notes"]}
        """)

    // MARK: 侧栏条目

    static func workspace(id: String, root: String, name: String?, lastOpenedAt: Date) -> Workspace {
        decode("""
            {"id":\(quoted(id)),"root":\(quoted(root)),"name":\(name.map(quoted) ?? "null"),\
            "last_opened_at":"\(iso(lastOpenedAt))"}
            """)
    }

    static func session(
        id: String,
        workspaceID: String,
        title: String?,
        lastPrompt: String?,
        cwd: String,
        at date: Date
    ) -> SessionSummary {
        decode("""
            {"id":\(quoted(id)),"workspace_id":\(quoted(workspaceID)),\
            "title":\(title.map(quoted) ?? "null"),"last_prompt":\(lastPrompt.map(quoted) ?? "null"),\
            "created_at":"\(iso(date))","updated_at":"\(iso(date))",\
            "busy":false,"pending_interaction":"none","metadata":{"cwd":\(quoted(cwd))}}
            """)
    }

    // MARK: transcript 片段

    /// 一轮对话 → transcript 页的 item JSON。frame 全放在一个 step 里。
    static func render(_ turn: DemoBackend.DemoTurn) -> String {
        let step: String
        if turn.frames.isEmpty {
            step = "[]"
        } else {
            step = """
                [{"stepId":"\(turn.turnID).s1","turnId":"\(turn.turnID)","ordinal":1,"state":"completed",\
                "startedAt":"\(iso(turn.startedAt))","endedAt":"\(iso(turn.endedAt ?? turn.startedAt))",\
                "frames":[\(turn.frames.joined(separator: ","))]}]
                """
        }
        let ended = turn.endedAt.map { #""endedAt":"\#(iso($0))""# } ?? ""
        let duration = turn.endedAt.map { #","durationMs":\#(Int($0.timeIntervalSince(turn.startedAt) * 1000))"# } ?? ""
        return """
            {"kind":"turn","turnId":"\(turn.turnID)","ordinal":\(Int(turn.turnID.dropFirst(2)) ?? 1),\
            "state":"\(turn.state)","prompt":\(quoted(turn.prompt)),\
            "startedAt":"\(iso(turn.startedAt))"\(ended.isEmpty ? "" : "," + ended)\(duration),\
            "steps":\(step)}
            """
    }

    static func page(items: [String], meta: String, seq: Int) -> TranscriptPage {
        decode("""
            {"items":[\(items.joined(separator: ","))],"tasks":[],"interactions":[],\
            "attachments":[],"prompts":[],"meta":\(meta),"has_more":false,"seq":\(seq)}
            """)
    }

    /// `meta.agent` 随正文一起推：模型 / 思考强度 / 权限 / 上下文圈都从这里读。
    static func meta(activity: String, profile: DemoBackend.Profile?, tokens: Int) -> String {
        let model = profile?.model ?? "kimi-code/k3"
        let effort = profile?.thinking ?? "low"
        let permission = (profile?.permission ?? .auto).rawValue
        return """
            {"activity":"\(activity)","agent":{"model":\(quoted(model)),\
            "thinkingEffort":\(quoted(effort)),"permission":\(quoted(permission)),\
            "contextTokens":\(tokens),"maxContextTokens":262144,\
            "contextUsage":\(Double(tokens) / 262144)}}
            """
    }

    static func thinkingFrame(id: String, text: String) -> String {
        #"{"kind":"thinking","frameId":"\#(id)","text":\#(quoted(text))}"#
    }

    static func textFrame(id: String, text: String) -> String {
        #"{"kind":"text","frameId":"\#(id)","role":"assistant","text":\#(quoted(text))}"#
    }

    /// `input` 是已经拼好的 JSON 片段（对象），`output` 是纯文本。
    static func toolFrame(id: String, callID: String, name: String, input: String, output: String) -> String {
        #"{"kind":"tool","frameId":"\#(id)","toolCallId":"\#(callID)","name":"\#(name)","state":"done","input":\#(input),"output":\#(quoted(output))}"#
    }
}
