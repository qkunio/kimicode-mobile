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
        } else {
            Color.clear
        }
    }
}

/// 一条对话的正文 + composer。
private struct ChatContent: View {
    let chat: ChatModel

    @State private var draft = ""
    @State private var ui = TranscriptUIState()
    @State private var undoTarget: UserEntry?
    /// 停在底部时新内容自动跟随（官方 isFollowing）；往上翻了就不打扰。
    @State private var isFollowing = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 不用 LazyVStack：高度差异大时它估不准，滚到底会落在空白里。
                // 一页只有 30 轮、折叠的部分本来就不渲染，普通 VStack 足够。
                VStack(alignment: .leading, spacing: 0) {
                    if chat.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.bottom, 16)
                    }

                    ConversationList(chat: chat, ui: ui) { entry in
                        undoTarget = entry
                    }

                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase, context in
                // 只在用户自己滑完之后判断：内容撑高不该把「跟随」关掉。
                guard phase == .idle else { return }
                // visibleRect 已经算上了底部 composer 的 inset。
                let geometry = context.geometry
                isFollowing = geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            }
            .contentShape(.rect)
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .onChange(of: chat.contentVersion) { if isFollowing { scrollToBottom(proxy, animated: false) } }
            .onChange(of: chat.optimisticPrompts.count) { scrollToBottom(proxy) }
        }
        // 用 safeAreaBar 而不是 safeAreaInset：只有前者参与 iOS 26 的滚动边缘效果，
        // 正文滚到 composer 后面时会像导航栏那样渐隐模糊。
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(chat.pendingQuestions) { question in
                    QuestionCard(request: question) { answers in
                        Task { await chat.answer(question, answers: answers) }
                    } dismiss: {
                        Task { await chat.dismiss(question) }
                    }
                }
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
        // 官方撤销前的确认框。
        .alert(
            "撤销",
            isPresented: .init(get: { undoTarget != nil }, set: { if !$0 { undoTarget = nil } }),
            presenting: undoTarget
        ) { entry in
            Button("取消", role: .cancel) {}
            Button("撤销") { Task { await chat.undo(entry) } }
        } message: { _ in
            Text("撤销后，这条消息及之后的会话内容会从上下文中移除，这条消息的原文会放回输入框；已修改的文件和代码不受影响。")
        }
        .onChange(of: chat.restoredDraft) { _, text in
            guard let text else { return }
            draft = text
            chat.restoredDraft = nil
        }
        .refreshable { await chat.reload() }
    }

    private static let bottomAnchor = "bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}
