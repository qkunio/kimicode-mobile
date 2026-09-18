import SwiftUI

/// 主页：左上角开侧栏，中间是对话，底部 composer。
struct ChatScreen: View {
    let openSidebar: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let chat = app.chat {
                ChatContent(chat: chat)
                    .id(chat.sessionID ?? "draft:\(chat.workspace?.id ?? "")")
            } else {
                placeholder
            }
        }
        .navigationTitle(app.chat?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openSidebar) {
                    Label("打开侧栏", systemImage: "line.3.horizontal")
                }
            }
            if app.chat != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    SessionInfoButton(chat: app.chat)
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !app.hasLoadedDevices || app.isLoadingDevices {
            ProgressView()
        } else if app.onlineDevices.isEmpty {
            ContentUnavailableView {
                Label("没有在线的设备", systemImage: "laptopcomputer.slash")
            } description: {
                Text("在电脑上运行 `kimi rc`，它就会出现在这里。")
            } actions: {
                Button("刷新") {
                    Task { await app.bootstrap() }
                }
                .buttonStyle(.glass)
            }
        } else if app.workspaces.isEmpty {
            ContentUnavailableView(
                "这台电脑上还没有文件夹",
                systemImage: "folder.badge.questionmark",
                description: Text("先在电脑上用 Kimi Code 打开一个项目目录。")
            )
        } else {
            ContentUnavailableView(
                "选一个会话",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("打开侧栏，挑一个会话，或在文件夹旁点 + 新建。")
            )
        }
    }
}

/// 一条对话的正文 + composer。
private struct ChatContent: View {
    let chat: ChatModel

    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    }

                    ForEach(chat.messages) { message in
                        TranscriptRow(message: message)
                            .id(message.id)
                    }

                    ForEach(chat.optimisticPrompts) { prompt in
                        OptimisticPromptRow(prompt: prompt) {
                            Task { await chat.retry(prompt) }
                        } discard: {
                            chat.discard(prompt)
                        }
                    }

                    if chat.isBusy, chat.pendingApprovals.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在执行…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if chat.isDraft, chat.optimisticPrompts.isEmpty {
                    DraftHint(folder: chat.workspace?.displayName)
                }
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.optimisticPrompts.count) { scrollToBottom(proxy) }
            .onChange(of: chat.isBusy) { scrollToBottom(proxy) }
        }
        // 用 safeAreaBar 而不是 safeAreaInset：只有前者参与 iOS 26 的滚动边缘效果，
        // 正文滚到 composer 后面时会像导航栏那样渐隐模糊。
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(chat.pendingApprovals) { approval in
                    ApprovalCard(approval: approval) { decision in
                        Task { await chat.resolve(approval, decision: decision) }
                    }
                }
                ComposerView(chat: chat, draft: $draft)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .alert(
            "出错了",
            isPresented: .init(
                get: { chat.errorMessage != nil },
                set: { if !$0 { chat.errorMessage = nil } }
            )
        ) {
            Button("好") { chat.errorMessage = nil }
        } message: {
            Text(chat.errorMessage ?? "")
        }
        .refreshable { await chat.reload() }
    }

    private static let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

private struct DraftHint: View {
    let folder: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.title2)
                .foregroundStyle(.tertiary)
            if let folder {
                Text(folder)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text("新对话")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }
}

private struct OptimisticPromptRow: View {
    let prompt: ChatModel.OptimisticPrompt
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .trailing, spacing: 4) {
                if prompt.attachmentCount > 0 {
                    Label("\(prompt.attachmentCount) 个附件", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !prompt.text.isEmpty {
                    Text(prompt.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(prompt.failed ? 0.12 : 0.22), in: .rect(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)

            if prompt.failed {
                HStack(spacing: 12) {
                    Label("没发出去", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重试", action: retry).font(.caption)
                    Button("丢弃", action: discard).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("发送中", systemImage: "arrow.up.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
