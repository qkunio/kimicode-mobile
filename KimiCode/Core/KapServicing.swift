import Foundation

/// 会话后端。登录后真机走 `KapClient`（relay → 电脑）；体验模式走 `DemoClient`（纯内存，不连任何服务器）。
protocol KapServicing: Sendable {
    // 侧栏 / 元信息
    func workspaces() async throws -> [Workspace]
    func addWorkspace(root: String) async throws -> Workspace
    func browseFs(_ path: String) async throws -> FsBrowse
    func fsHome() async throws -> FsHome
    func sessions(pageSize: Int) async throws -> SessionList
    func models() async throws -> [ModelInfo]
    func configDefaults() async throws -> ServerConfigDefaults
    func usage() async throws -> PlanUsage
    func userInfo() async throws -> KimiUser?

    // 会话
    func status(_ sessionID: String) async throws -> SessionRuntimeStatus
    @discardableResult
    func updateProfile(_ sessionID: String, agentConfig: AgentConfigPatch) async throws -> SessionSummary
    @discardableResult
    func renameSession(_ sessionID: String, title: String) async throws -> SessionSummary
    func deleteSession(_ sessionID: String) async throws
    func transcript(_ sessionID: String, pageSize: Int, beforeTurn: String?) async throws -> TranscriptPage
    func undo(_ sessionID: String, count: Int) async throws
    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary

    // 发任务 / 打断
    func sendPrompt(_ body: PromptBody, to sessionID: String) async throws -> PromptAccepted
    func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> UploadedFile
    func abort(_ sessionID: String) async throws

    // 权限确认 / 提问
    func pendingApprovals(_ sessionID: String) async throws -> ApprovalList
    func resolve(approval approvalID: String, in sessionID: String, with decision: ApprovalDecisionBody) async throws -> Bool
    func pendingQuestions(_ sessionID: String) async throws -> QuestionList
    func answer(question questionID: String, in sessionID: String, with body: QuestionAnswerBody) async throws -> Bool
    func dismiss(question questionID: String, in sessionID: String) async throws
}

extension KapClient: KapServicing {}

extension KapServicing {
    func sessions() async throws -> SessionList {
        try await sessions(pageSize: 100)
    }

    func transcript(_ sessionID: String) async throws -> TranscriptPage {
        try await transcript(sessionID, pageSize: 30, beforeTurn: nil)
    }

    func transcript(_ sessionID: String, beforeTurn: String?) async throws -> TranscriptPage {
        try await transcript(sessionID, pageSize: 30, beforeTurn: beforeTurn)
    }
}
