import SwiftUI

/// 侧栏：
///   KIMI CODE
///   设备 (MAC ▾)
///   📁 Folder1                        (+)
///      ○ Session1
///      ○ Session2
///   📁 Folder2                        (+)
///   ───────────────────────────────
///   (头像) 昵称                    [退出登录]
struct SidebarView: View {
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @State private var collapsed: Set<String> = []
    @State private var isConfirmingSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            deviceRow
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

            folderList

            Divider()
            accountRow
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .alert("是否退出登录？", isPresented: $isConfirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { app.signOut() }
        }
    }

    // MARK: 头部

    private var header: some View {
        Text("KIMI CODE")
            .font(.system(.title2, weight: .black))
            .tracking(0.5)
            .frame(height: 44)
    }

    // MARK: 底部账号

    private var accountRow: some View {
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
    }

    private var deviceRow: some View {
        HStack(spacing: 10) {
            Text("设备")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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

    // MARK: 文件夹 / 会话

    private var folderList: some View {
        List {
            // 文件夹也画成普通行而不是 section header：sidebar 样式下 header 里的按钮收不到点击，
            // 普通行可以。点文件夹名展开/收起，右侧 + 新建会话。
            ForEach(app.workspaces) { workspace in
                folderRow(workspace)
                if !collapsed.contains(workspace.id) {
                    ForEach(app.sessions(in: workspace)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .refreshable {
            await app.refreshDevices()
            await app.refreshSidebar()
        }
        .overlay {
            if app.endpoint != nil, app.workspaces.isEmpty {
                Text("这台电脑上还没有会话")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                HStack {
                    Label(workspace.displayName, systemImage: "folder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(collapsed.contains(workspace.id) ? "展开会话" : "收起会话")

            Button {
                app.newChat(in: workspace)
                close()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("在 \(workspace.displayName) 新建会话")
        }
        .padding(.top, 10)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let isCurrent = session.id == app.chat?.sessionID
        return Button {
            app.open(session)
            close()
        } label: {
            HStack(spacing: 10) {
                SessionStateDot(session: session)
                Text(session.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
        // 原型里会话是文件夹下的一串圆点条目，不要系统 sidebar 那种白卡片；只有当前会话高亮。
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear)
                .padding(.horizontal, 8)
        )
        .listRowSeparator(.hidden)
    }
}

/// 会话前面那个小圆：空闲是空心圈，执行中转圈，待你确认/回答是橙色。
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
