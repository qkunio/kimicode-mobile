import SwiftUI

/// 侧栏：
///   KIMI CODE
///   设备 (MAC ▾)
///   📁 Folder1                        (+)
///        Session1
///        Session2
///   📁 Folder2                        (+)
///   ───────────────────────────────
///   (头像) 昵称                    [退出登录]
struct SidebarView: View {
    let close: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
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
        .background(
            Color(colorScheme == .dark ? .secondarySystemBackground : .systemGroupedBackground)
        )
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
