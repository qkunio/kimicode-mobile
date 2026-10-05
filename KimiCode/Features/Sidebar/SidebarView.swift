import SwiftUI

/// 侧栏：
///   Kimi Code Mobile
///   📁+ 添加文件夹
///   📁 Folder1                        (+)
///        Session1
///        Session2
///   📁 Folder2                        (+)
///   ╭ (头像) 昵称 >            [退出登录] ╮   ← 悬浮胶囊卡片，和输入框同一种玻璃
///   ║  💻 MacBook-Pro        ✓           ║   ← 点昵称展开设备面板：切换 / 刷新
///   ╰────────────────────────────────────╯

struct SidebarView: View {
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed: Set<String> = []
    @State private var isConfirmingSignOut = false
    @State private var isAddingWorkspace = false
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var deleting: SessionSummary?
    /// 账号卡展开设备面板。
    @State private var showsDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            addFolderRow
                .padding(.horizontal, 20)
                .padding(.top, 14)

            folderList
                // 和主页 composer 一样用 safeAreaBar：列表滚到卡片后面时渐隐模糊。
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    accountCard
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
        }
        .background(
            Color(colorScheme == .dark ? .secondarySystemBackground : .systemGroupedBackground)
        )
        .sheet(isPresented: $isAddingWorkspace) {
            if let client = app.client {
                AddWorkspaceSheet(client: client) { root in
                    try await app.addWorkspace(root: root)
                    // 已在新项目里开好新对话，收起侧栏直接进去。
                    close()
                }
                .presentationDetents([.large])
            }
        }
        // 长按会话：重命名 / 删除对话。
        .alert("重命名", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { session in
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") { Task { await app.rename(session, to: renameText) } }
        }
        .alert("删除会话", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { session in
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { Task { await app.delete(session) } }
        } message: { session in
            Text("将永久删除「\(session.displayTitle)」的全部对话记录，无法恢复。工作区里的文件和代码改动不受影响。")
        }
        .alert(app.isDemoMode ? "退出体验模式？" : "是否退出登录？", isPresented: $isConfirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { app.signOut() }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            KimiFace(animating: false)
                .scaleEffect(1.25)
                .frame(width: 30, height: 20)
            (Text("Kimi Code ") + Text("Mobile").foregroundStyle(Palette.kimi))
                .font(.system(.title2, weight: .black))
        }
        .frame(height: 44)
    }

    // MARK: 底部账号

    /// 用户栏标题：直接显示当前设备名，没连设备时引导选择。
    private var accountTitle: String {
        app.currentDevice?.shortName ?? "选择设备"
    }

    /// 悬浮的胶囊卡片（参考输入框：同一种玻璃，列表从它下面滚过去）。
    /// 点昵称展开/收起设备面板：在线设备可切换、离线置灰，底部有刷新。
    private var accountCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Avatar(url: app.user?.avatarURL)
                Button {
                    withAnimation(.snappy) {
                        showsDevices.toggle()
                    }
                    // 每次展开顺手拉一次最新状态。
                    if showsDevices { Task { await app.refreshDevices() } }
                } label: {
                    HStack(spacing: 4) {
                        Text(accountTitle)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsDevices ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设备")
                .accessibilityHint(showsDevices ? "收起设备面板" : "展开设备面板")
                Spacer(minLength: 8)
                Button {
                    isConfirmingSignOut = true
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(width: 38, height: 38)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.isDemoMode ? "退出体验" : "退出登录")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            if showsDevices {
                devicePanel
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .glassEffect(in: showsDevices ? AnyShape(.rect(cornerRadius: 28)) : AnyShape(.capsule))
    }

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.bottom, 4)

            ForEach(app.devices) { device in
                Button {
                    Task { await app.select(device) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.symbolName)
                            .frame(width: 22)
                        Text(device.shortName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if device.deviceID == app.endpoint?.deviceID {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.kimi)
                        } else if !device.isOnline {
                            Text("离线")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(device.isOnline ? .primary : .tertiary)
                    .frame(minHeight: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!device.isOnline)
            }

            Button {
                Task { await app.refreshDevices() }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if app.isLoadingDevices {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 22)
                    Text("刷新设备")
                    Spacer(minLength: 4)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(app.isLoadingDevices)
        }
    }

    /// 选一个电脑上的文件夹加成工作区（官方网页端「添加工作区」）。样式与下面的文件夹行一致。
    private var addFolderRow: some View {
        Button {
            isAddingWorkspace = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 24)
                Text("添加文件夹")
                    .font(.body)
                Spacer(minLength: 4)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(app.client == nil)
    }

    // MARK: 文件夹 / 会话

    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(app.workspaces) { workspace in
                    folderRow(workspace)
                    if !collapsed.contains(workspace.id) {
                        ForEach(app.sessions(in: workspace)) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
        }
        .refreshable {
            await app.refreshDevices()
            await app.refreshSidebar()
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    private func folderRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(workspace.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 24)
                    Text(workspace.displayName)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(collapsed.contains(workspace.id) ? "展开会话" : "收起会话")

            Button {
                app.newChat(in: workspace)
                close()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 \(workspace.displayName) 新建会话")
        }
        .padding(.leading, 14)
        .padding(.top, 12)
        .frame(minHeight: 52)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let isCurrent = session.id == app.chat?.sessionID
        return Button {
            app.open(session)
            close()
        } label: {
            HStack(spacing: 8) {
                Text(session.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if session.pendingInteraction != .none || session.busy {
                    SessionStateDot(session: session)
                }
            }
            .padding(.leading, 50)
            .padding(.trailing, 14)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isCurrent ? Color(.tertiarySystemFill) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = session
            } label: {
                Label("删除对话", systemImage: "trash")
            }
        }
    }

}

/// 会话尾部的活动状态：执行中转圈，待确认/回答时显示橙色标记。
private struct SessionStateDot: View {
    let session: SessionSummary

    var body: some View {
        Group {
            if session.pendingInteraction != .none {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else if session.busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .frame(width: 16)
    }
}

// MARK: - 头像

private struct Avatar: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
