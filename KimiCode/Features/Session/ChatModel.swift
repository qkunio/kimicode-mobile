import Foundation
import Observation

/// composer 上那一排的选择：权限模式 / 模型 / 思考强度。新会话会继承上一次的选择。
struct ComposerConfig: Codable, Equatable, Sendable {
    var permission: PermissionMode
    var modelID: String?
    var effort: String?

    var patch: AgentConfigPatch {
        AgentConfigPatch(model: modelID, thinking: effort, permissionMode: permission)
    }
}

/// 主页正在看的那条对话。
///
/// 两种形态：
///   - 已有会话：`session != nil`，composer 配置从 `/status` 读，改动走 `/profile`
///   - 新对话草稿：只知道在哪个文件夹（工作区），第一条消息发出时才 `POST /sessions`
///
/// 数据流：REST 拿权威历史，WS 当"有什么变了"的信号（见 CLAUDE.md 架构决定）。
@MainActor
@Observable
final class ChatModel {
    private(set) var session: SessionSummary?
    let workspace: Workspace?

    private(set) var messages: [HistoryMessage] = []
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var isBusy = false
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var connectionState: ConnectionState = .idle
    var errorMessage: String?

    // composer
    private(set) var config: ComposerConfig
    private(set) var contextTokens: Int?
    private(set) var maxContextTokens: Int?
    private(set) var contextUsage: Double?
    var attachments: [Attachment] = []

    /// 正在发送但还没出现在历史里的用户消息，先乐观显示。
    private(set) var optimisticPrompts: [OptimisticPrompt] = []

    enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case live
        case offline(String)
    }

    struct OptimisticPrompt: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let attachmentCount: Int
        var failed = false
    }

    private let client: KapClient
    private let endpoint: Endpoint
    private let tokenProvider: @Sendable () async -> String?
    private let onSessionCreated: (SessionSummary) -> Void
    private let onConfigChanged: (ComposerConfig) -> Void

    private var stream: EventStream?
    private var streamTask: Task<Void, Never>?
    private let refreshScheduler = RefreshScheduler()

    var isDraft: Bool { session == nil }
    var sessionID: String? { session?.id }

    var title: String {
        if let session { return session.displayTitle }
        return workspace?.displayName ?? "新对话"
    }

    init(
        session: SessionSummary?,
        workspace: Workspace?,
        config: ComposerConfig,
        client: KapClient,
        endpoint: Endpoint,
        tokenProvider: @escaping @Sendable () async -> String?,
        onSessionCreated: @escaping (SessionSummary) -> Void,
        onConfigChanged: @escaping (ComposerConfig) -> Void
    ) {
        self.session = session
        self.workspace = workspace
        self.config = config
        self.client = client
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.onSessionCreated = onSessionCreated
        self.onConfigChanged = onConfigChanged
    }

    // MARK: 生命周期

    func start() async {
        guard let sessionID else { return }
        await reload()
        guard streamTask == nil else { return }
        connectionState = .connecting
        let stream = EventStream(endpoint: endpoint, tokenProvider: tokenProvider)
        self.stream = stream
        let signals = await stream.start()
        await stream.subscribe(to: sessionID)
        streamTask = Task { [weak self] in
            for await signal in signals {
                await self?.handle(signal)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        refreshScheduler.cancel()
        let stream = stream
        self.stream = nil
        Task { await stream?.stop() }
    }

    // MARK: 读

    func reload() async {
        guard let sessionID else { return }
        isLoading = messages.isEmpty
        defer { isLoading = false }
        do {
            async let history = client.history(sessionID)
            async let approvals = client.pendingApprovals(sessionID)
            async let status = client.status(sessionID)

            let page = try await history
            // 主 agent 的消息按时间排；子 agent 的留给 task 面板（后续里程碑）。
            messages = page.messages
                .filter { $0.agentID == nil || $0.agentID == "main" }
                .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
            pendingApprovals = try await approvals.items
            apply(try await status)
            errorMessage = nil

            // 历史里已经出现的 prompt 就不用再乐观显示了。
            let known = Set(messages.compactMap { message -> String? in
                if case let .user(user) = message { return user.plainText }
                return nil
            })
            optimisticPrompts.removeAll { !$0.failed && known.contains($0.text) }
        } catch {
            // 切换会话/停止订阅取消的是读取任务，不代表消息发送失败。
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ status: SessionRuntimeStatus) {
        isBusy = status.busy ?? false
        contextTokens = status.contextTokens
        maxContextTokens = status.maxContextTokens
        contextUsage = status.contextUsage
        config = ComposerConfig(
            permission: status.permission ?? config.permission,
            modelID: status.model ?? config.modelID,
            effort: status.thinkingLevel ?? config.effort
        )
    }

    /// 合并流式事件；已有请求继续执行，其间收到的事件在下一轮补齐。
    private func scheduleRefresh(after delay: Duration = .milliseconds(400)) {
        refreshScheduler.schedule(after: delay) { [weak self] in
            await self?.reload()
        }
    }

    // MARK: composer 配置

    func setPermission(_ permission: PermissionMode) async {
        await update { $0.permission = permission }
    }

    func setModel(_ model: ModelInfo, effort: String?) async {
        await update {
            $0.modelID = model.model
            $0.effort = effort
        }
    }

    private func update(_ change: (inout ComposerConfig) -> Void) async {
        let previous = config
        var next = config
        change(&next)
        guard next != previous else { return }
        config = next
        onConfigChanged(next)
        // 草稿还没有会话，等第一条消息时连同配置一起建。
        guard let sessionID else { return }
        do {
            try await client.updateProfile(sessionID, agentConfig: diff(from: previous, to: next))
            if let status = try? await client.status(sessionID) { apply(status) }
        } catch {
            config = previous
            errorMessage = error.localizedDescription
        }
    }

    private func diff(from old: ComposerConfig, to new: ComposerConfig) -> AgentConfigPatch {
        AgentConfigPatch(
            model: new.modelID != old.modelID ? new.modelID : nil,
            thinking: new.effort != old.effort || new.modelID != old.modelID ? new.effort : nil,
            permissionMode: new.permission != old.permission ? new.permission : nil
        )
    }

    // MARK: 写

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = attachments
        guard !trimmed.isEmpty || !pending.isEmpty else { return }

        let optimistic = OptimisticPrompt(text: trimmed, attachmentCount: pending.count)
        optimisticPrompts.append(optimistic)
        attachments = []
        isSending = true
        defer { isSending = false }

        do {
            // 草稿：先在对应文件夹里建会话（带上 composer 里选好的配置），再发消息。
            if session == nil {
                guard let workspace else {
                    throw KapError.api(code: -1, message: "先在侧栏选一个文件夹。")
                }
                let created = try await client.createSession(in: workspace, agentConfig: config.patch)
                session = created
                onSessionCreated(created)
                await start()
            }
            guard let sessionID else { return }
            var images: [Data] = []
            var files: [UploadedFile] = []
            for attachment in pending {
                switch attachment {
                case let .image(_, jpeg, _):
                    images.append(jpeg)
                case let .file(_, name, mediaType, data):
                    files.append(try await client.uploadFile(data, name: name, mediaType: mediaType))
                }
            }
            _ = try await client.sendPrompt(.make(text: trimmed, images: images, files: files), to: sessionID)
            isBusy = true
            scheduleRefresh(after: .milliseconds(600))
        } catch {
            errorMessage = error.localizedDescription
            if let index = optimisticPrompts.firstIndex(where: { $0.id == optimistic.id }) {
                optimisticPrompts[index].failed = true
            }
        }
    }

    func retry(_ prompt: OptimisticPrompt) async {
        optimisticPrompts.removeAll { $0.id == prompt.id }
        await send(prompt.text)
    }

    func discard(_ prompt: OptimisticPrompt) {
        optimisticPrompts.removeAll { $0.id == prompt.id }
    }

    func abort() async {
        guard let sessionID else { return }
        do {
            try await client.abort(sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
        scheduleRefresh(after: .milliseconds(300))
    }

    func resolve(_ approval: ApprovalRequest, decision: ApprovalDecisionBody) async {
        guard let sessionID else { return }
        // 先乐观移除，失败再放回去。
        let snapshot = pendingApprovals
        pendingApprovals.removeAll { $0.approvalID == approval.approvalID }
        do {
            let resolved = try await client.resolve(
                approval: approval.approvalID,
                in: sessionID,
                with: decision
            )
            if !resolved {
                errorMessage = "这条确认已经在别处处理过了。"
            }
            scheduleRefresh(after: .milliseconds(300))
        } catch {
            errorMessage = error.localizedDescription
            pendingApprovals = snapshot
        }
    }

    // MARK: 事件

    private func handle(_ signal: StreamSignal) async {
        switch signal {
        case .connected:
            connectionState = .live
            await reload()

        case let .disconnected(reason):
            connectionState = .offline(reason)

        case let .resyncRequired(sessions):
            if sessions.isEmpty || sessions.contains(sessionID ?? "") {
                await reload()
            }

        case let .event(event):
            guard event.sessionID == nil || event.sessionID == sessionID else { return }
            apply(event)
        }
    }

    private func apply(_ event: SessionEventFrame) {
        switch event.type {
        // 流式增量：正文靠重拉补齐，这里只用来点亮"正在工作"。
        case "assistant.delta", "event.assistant.delta", "thinking.delta":
            isBusy = true
            scheduleRefresh(after: .milliseconds(700))

        case "activity.agent_busy", "turn.started", "event.session.work_changed":
            isBusy = true
            scheduleRefresh()

        case "turn.completed", "turn.failed", "turn.cancelled", "activity.cancelling":
            isBusy = false
            scheduleRefresh()

        case "awaiting_approval", "approval.requested", "interaction.requested",
             "approval.resolved", "interaction.resolved":
            scheduleRefresh(after: .milliseconds(150))

        case "event.session.status_changed":
            if let busy = event.payload?["busy"]?.boolValue { isBusy = busy }
            scheduleRefresh()

        default:
            // 没见过的事件：不猜语义，刷一次权威状态。
            scheduleRefresh()
        }
    }
}
