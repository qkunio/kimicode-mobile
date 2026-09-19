import SwiftUI

/// 主页：左上角开侧栏，中间是对话，底部 composer。
struct ChatScreen: View {
    let openSidebar: () -> Void

    @Environment(AppModel.self) private var app
    @State private var isAddingWorkspace = false

    var body: some View {
        Group {
            if let chat = app.chat {
                ChatContent(chat: chat)
                    .id(chat.sessionID ?? "draft:\(chat.workspace?.id ?? "")")
            } else {
                placeholder
            }
        }
        // 顶部不显示会话标题。
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingWorkspace) {
            if let client = app.client {
                AddWorkspaceSheet(client: client) { root in
                    try await app.addWorkspace(root: root)
                }
                .presentationDetents([.large])
            }
        }
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
            // 电脑上一个文件夹都没有：先引导添加，加完 AppModel 会自动开一个新对话。
            WelcomeHero {
                HStack(spacing: 0) {
                    Button {
                        isAddingWorkspace = true
                    } label: {
                        // 系统下划线贴字太紧，自己画一条往下挪 4pt。
                        Text("打开文件夹")
                            .overlay(alignment: .bottom) {
                                Rectangle().frame(height: 1.5).offset(y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    Text("，我们开始创造吧")
                }
            }
            // 这一页没有输入框，按整块屏幕居中，不算顶部栏。
            .ignoresSafeArea()
        } else {
            Color.clear
        }
    }
}

/// 空白对话中间的欢迎：会动的 Kimi 小脸 + 一句话。
struct WelcomeHero<Message: View>: View {
    @ViewBuilder var message: Message

    var body: some View {
        VStack(spacing: 28) {
            KimiFace(animating: true)
                .scaleEffect(3)
                .frame(width: 72, height: 48)
            message
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                // 按屏幕宽度排版（overlay 里给的宽度不可靠，会被挤成一列）。
                .containerRelativeFrame(.horizontal) { width, _ in width - 48 }
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// 离底部超过一屏的一半就显示「回到底部」按钮。
    @State private var showsJumpToBottom = false

    var body: some View {
        Group {
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
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .overlay {
                // 新对话还没发任何东西：中间放欢迎语。
                if chat.isDraft, chat.entries.isEmpty, chat.optimisticPrompts.isEmpty {
                    WelcomeHero {
                        Text("你来啦，在\(chat.workspace?.displayName ?? "这里")里开始创造吧")
                    }
                    .allowsHitTesting(false)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 键盘弹出（或确认卡片出现）时底部 inset 变大：本来停在底部的话，聊天记录跟着一起往上推，
            // 在同一个布局事务里滚，和键盘动画同步。
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { old, new in
                guard new > old, isFollowing else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY > geometry.containerSize.height / 2
            } action: { _, far in
                withAnimation(.snappy(duration: 0.2)) { showsJumpToBottom = far }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    // 手指一放上去就停止跟随：回答生成中也能往上翻，不会被新内容拽回底部。
                    isFollowing = false
                case .idle:
                    // 滑完停在底部附近才恢复跟随。visibleRect 已经算上了底部 composer 的 inset。
                    let geometry = context.geometry
                    isFollowing = geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                default:
                    break
                }
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
            .onChange(of: chat.contentVersion) { if isFollowing { scrollToBottom(animated: false) } }
            // 一轮结束时「工作中」那行换成页脚，高度会变，再贴一次底。
            .onChange(of: chat.isWorking) { if isFollowing { scrollToBottom() } }
            .onChange(of: chat.optimisticPrompts.count) { scrollToBottom() }
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
                // 等你确认 / 回答时只留卡片，输入框先收起来（草稿还在）。
                if !isAwaitingInteraction {
                    ComposerView(chat: chat, draft: $draft)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // 按钮浮在底栏上方，不算进底栏高度：否则 iOS 26 的边缘毛玻璃会跟着往上扩一截。
            .overlay(alignment: .top) {
                if showsJumpToBottom {
                    jumpToBottomButton
                        .offset(y: -52)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
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
        .onChange(of: isAwaitingInteraction) { _, awaiting in
            guard awaiting else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: chat.restoredDraft) { _, text in
            guard let text else { return }
            draft = text
            chat.restoredDraft = nil
        }
        .refreshable { await chat.reload() }
    }

    /// 一键回到底部，并恢复跟随新内容。
    private var jumpToBottomButton: some View {
        Button {
            isFollowing = true
            scrollToBottom()
        } label: {
            // 实底圆 + 细边，不用玻璃：玻璃会把后面的正文糊成一圈。
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(Color(.systemBackground), in: .circle)
                .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到底部")
    }

    private var isAwaitingInteraction: Bool {
        !chat.pendingApprovals.isEmpty || !chat.pendingQuestions.isEmpty
    }

    /// 滚到内容真正的末尾（含底部 inset）。内容刚变时新行可能还没排版，
    /// 所以下一轮主线程滚一次，布局稳定后（约 0.15s）再补一次。
    private func scrollToBottom(animated: Bool = true) {
        let scroll = {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        DispatchQueue.main.async(execute: scroll)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard isFollowing else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}
