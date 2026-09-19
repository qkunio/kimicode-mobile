import SwiftUI

/// 侧栏：
///   Kimi Code Mobile
///   设备 (MAC ▾)
///   📁+ 添加文件夹
///   📁 Folder1                        (+)
///        Session1
///        Session2
///   📁 Folder2                        (+)
///   ╭ (头像) 昵称                  [退出登录] ╮   ← 悬浮胶囊卡片，和输入框同一种玻璃

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            deviceRow
                .padding(.horizontal, 20)
                .padding(.top, 14)

            // 「设备」→「添加文件夹」与「添加文件夹」→ 第一个文件夹的行距一致（都是 55pt）。
            addFolderRow
                .padding(.horizontal, 20)
                .padding(.top, 17)

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
        .alert("是否退出登录？", isPresented: $isConfirmingSignOut) {
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

    /// 悬浮的胶囊卡片（参考输入框：同一种玻璃，列表从它下面滚过去）。
    private var accountCard: some View {
        HStack(spacing: 12) {
            Avatar(url: app.user?.avatarURL)
            Text(app.user?.displayName ?? "Kimi 用户")
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                isConfirmingSignOut = true
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出登录")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }

    private var deviceRow: some View {
        HStack(spacing: 10) {
            // 与文件夹标题同一字号。
            Text("设备")
                .font(.body)
                .foregroundStyle(.primary)

            Menu {
                Section("在线") {
                    ForEach(app.onlineDevices) { device in
                        Button {
                            Task { await app.select(device) }
                        } label: {
                            if device.deviceID == app.endpoint?.deviceID {
                                Label(device.shortName, systemImage: "checkmark")
                            } else {
                                Label(device.shortName, systemImage: device.symbolName)
                            }
                        }
                    }
                }
                let offline = app.devices.filter { !$0.isOnline }
                if !offline.isEmpty {
                    Section("离线") {
                        ForEach(offline) { device in
                            Label(device.shortName, systemImage: device.symbolName)
                        }
                        .disabled(true)
                    }
                }
                Divider()
                Button {
                    Task { await app.refreshDevices() }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
            } label: {
                HStack(spacing: 6) {
                    if let device = app.currentDevice {
                        Image(systemName: device.symbolName)
                        Text(device.shortName)
                            .lineLimit(1)
                    } else {
                        Text("选择设备")
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                // 与输入框上 + / 权限按钮同一种灰底（它们在输入卡片里呈灰色），不用 glass 的白底加阴影。
                .background(Color(.tertiarySystemFill), in: .capsule)
            }
            .foregroundStyle(.primary)

            Spacer(minLength: 0)
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
