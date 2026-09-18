import Foundation
import Observation

/// App 级状态：账号、当前设备、侧栏数据（文件夹/会话/用量）、主页正在看的对话。
@MainActor
@Observable
final class AppModel {
    let auth = AuthStore()

    // 设备
    private(set) var devices: [RemoteDevice] = []
    private(set) var endpoint: Endpoint?
    private(set) var hasLoadedDevices = false
    var isLoadingDevices = false

    // 侧栏
    private(set) var workspaces: [Workspace] = []
    private(set) var sessions: [SessionSummary] = []
    private(set) var user: KimiUser?
    /// 订阅剩余用量，打开会话右上角 ⋯ 时刷新。
    private(set) var usage: PlanUsage?

    // composer 用
    private(set) var models: [ModelInfo] = []
    private(set) var defaultModelID: String?

    /// 主页正在看的对话。
    private(set) var chat: ChatModel?

    var errorMessage: String?

    private static let lastDeviceKey = "kimi.lastDeviceID"
    private static let composerConfigKey = "kimi.composerConfig"

    // MARK: 客户端

    /// 每次请求都重新取 token：refresh 之后旧的那份就作废了。
    /// `AuthStore` 是 `@MainActor` 隔离的类，所以隐式 Sendable，可以直接捕获。
    private var tokenProvider: @Sendable () async -> String? {
        let auth = auth
        return { @Sendable in
            await auth.refreshIfNeeded()
            return await auth.bearerToken
        }
    }

    var client: KapClient? {
        guard let endpoint else { return nil }
        return KapClient(endpoint: endpoint, tokenProvider: tokenProvider)
    }

    private var relay: RelayClient {
        RelayClient(origin: KimiConfig.relayOrigin, tokenProvider: tokenProvider)
    }

    var currentDevice: RemoteDevice? {
        devices.first { $0.deviceID == endpoint?.deviceID }
    }

    var onlineDevices: [RemoteDevice] { devices.filter(\.isOnline) }

    // MARK: 启动

    /// 登录后调用：拉设备 → 选上次那台（还在线的话）或第一台在线的 → 拉它的数据 → 打开一个新对话。
    func bootstrap() async {
        await refreshDevices()
        guard endpoint == nil else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        let pick = onlineDevices.first { $0.deviceID == last } ?? onlineDevices.first
        if let pick { await select(pick) }
    }

    func refreshDevices() async {
        guard auth.isSignedIn else { return }
        isLoadingDevices = true
        defer {
            isLoadingDevices = false
            hasLoadedDevices = true
        }
        do {
            let list = try await relay.devices()
            devices = list.devices.sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
                return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func select(_ device: RemoteDevice) async {
        guard device.deviceID != endpoint?.deviceID else { return }
        chat?.stop()
        chat = nil
        workspaces = []
        sessions = []
        models = []
        usage = nil
        endpoint = .remote(deviceID: device.deviceID, name: device.shortName)
        UserDefaults.standard.set(device.deviceID, forKey: Self.lastDeviceKey)

        await refreshDeviceData()
        if chat == nil, let workspace = workspaces.first {
            newChat(in: workspace)
        }
    }

    /// 一次拉齐侧栏和 composer 需要的东西。
    func refreshDeviceData() async {
        guard let client else { return }
        async let workspaces = client.workspaces()
        async let sessions = client.sessions()
        async let models = client.models()
        async let config = client.configDefaults()
        async let user = client.userInfo()

        do {
            self.workspaces = try await workspaces.sorted {
                ($0.lastOpenedAt?.date ?? .distantPast) > ($1.lastOpenedAt?.date ?? .distantPast)
            }
            self.sessions = try await sessions.items
            errorMessage = nil
        } catch {
            handle(error)
        }
        // 下面几项失败不影响主流程。
        // 只保留「Kimi 订阅」组的模型，顺序沿用服务端返回的。
        self.models = ((try? await models) ?? []).filter(\.isKimiSubscription)
        self.defaultModelID = (try? await config)?.defaultModel
        if let value = try? await user { self.user = value }
    }

    /// 打开侧栏时刷新：会话状态（忙/待确认）变化最快。
    func refreshSidebar() async {
        guard let client else { return }
        async let sessions = client.sessions()
        async let workspaces = client.workspaces()
        if let items = try? await sessions.items { self.sessions = items }
        if let items = try? await workspaces {
            self.workspaces = items.sorted {
                ($0.lastOpenedAt?.date ?? .distantPast) > ($1.lastOpenedAt?.date ?? .distantPast)
            }
        }
    }

    func refreshUsage() async {
        guard let client else { return }
        if let value = try? await client.usage() { usage = value }
    }

    // MARK: 侧栏分组

    /// 某个文件夹下的会话，最近活动的在前。
    func sessions(in workspace: Workspace) -> [SessionSummary] {
        sessions
            .filter { $0.workspaceID == workspace.id && $0.archived != true }
            .sorted { ($0.updatedAt?.date ?? .distantPast) > ($1.updatedAt?.date ?? .distantPast) }
    }

    func model(withID id: String?) -> ModelInfo? {
        guard let id else { return nil }
        return models.first { $0.model == id }
    }

    // MARK: 打开对话

    func open(_ session: SessionSummary) {
        guard session.id != chat?.sessionID else { return }
        let workspace = workspaces.first { $0.id == session.workspaceID }
        replaceChat(with: makeChat(session: session, workspace: workspace))
    }

    func newChat(in workspace: Workspace) {
        replaceChat(with: makeChat(session: nil, workspace: workspace))
    }

    private func replaceChat(with next: ChatModel?) {
        chat?.stop()
        chat = next
        if let next { Task { await next.start() } }
    }

    private func makeChat(session: SessionSummary?, workspace: Workspace?) -> ChatModel? {
        guard let client, let endpoint else { return nil }
        return ChatModel(
            session: session,
            workspace: workspace,
            config: initialComposerConfig,
            client: client,
            endpoint: endpoint,
            tokenProvider: tokenProvider,
            onSessionCreated: { [weak self] created in
                self?.sessions.insert(created, at: 0)
            },
            onConfigChanged: { [weak self] config in
                self?.rememberComposerConfig(config)
            }
        )
    }

    /// 新对话继承上次的选择；第一次用时：权限「完全自动」（服务端默认）、服务端默认模型及其默认思考强度。
    /// 模型必须在「Kimi 订阅」组里：记住的或服务端默认的不是这组的，就退到这组第一个。
    private var initialComposerConfig: ComposerConfig {
        if let data = UserDefaults.standard.data(forKey: Self.composerConfigKey),
           let stored = try? JSONDecoder().decode(ComposerConfig.self, from: data),
           model(withID: stored.modelID) != nil {
            return stored
        }
        let modelID = model(withID: defaultModelID)?.model ?? models.first?.model
        return ComposerConfig(
            permission: .auto,
            modelID: modelID,
            effort: model(withID: modelID)?.defaultEffort
        )
    }

    private func rememberComposerConfig(_ config: ComposerConfig) {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: Self.composerConfigKey)
    }

    // MARK: 账号

    func signOut() {
        chat?.stop()
        chat = nil
        endpoint = nil
        devices = []
        workspaces = []
        sessions = []
        user = nil
        usage = nil
        models = []
        hasLoadedDevices = false
        auth.signOut()
    }

    private func handle(_ error: any Error) {
        if let kapError = error as? KapError, kapError.requiresReauth {
            signOut()
            return
        }
        errorMessage = error.localizedDescription
    }
}

extension RemoteDevice {
    /// 「MacBook-Air.local」→「MacBook-Air」
    var shortName: String {
        alias.hasSuffix(".local") ? String(alias.dropLast(6)) : alias
    }
}
