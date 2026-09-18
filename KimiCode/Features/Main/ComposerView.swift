import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 底部输入卡片：（+）（权限图标）K3·Low（↑）。上下文占用在会话右上角 ⋯ 里看。
///
///   - ＋        菜单：图片（当前模型不收图时禁用）/ 文件
///   - 权限图标  与网页端同三档：始终询问 / 必要时询问 / 完全自动，文字只在菜单里出现
///   - K3·Low    模型与思考强度
///   - ↑ / ■     发送；忙且没输入时变成停止
struct ComposerView: View {
    let chat: ChatModel
    @Binding var draft: String

    @Environment(AppModel.self) private var app
    @FocusState private var isFocused: Bool
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var attachmentError: String?

    /// 隧道单请求上限 10 MiB，multipart 再加点开销，文件卡在 9 MB。
    private static let maxFileBytes = 9 * 1024 * 1024

    private var currentModel: ModelInfo? { app.model(withID: chat.config.modelID) }

    private var canSend: Bool {
        !chat.isSending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chat.attachments.isEmpty {
                AttachmentStrip(chat: chat)
            }

            TextField("让 Kimi 做点什么…", text: $draft, axis: .vertical)
                .lineLimit(1 ... 6)
                .focused($isFocused)
                .padding(.horizontal, 4)

            HStack(spacing: 6) {
                attachButton
                permissionMenu
                modelMenu
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(12)
        .glassEffect(in: .rect(cornerRadius: 26))
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: 4,
            matching: .images
        )
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { loadFiles(urls) }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await load(items) }
        }
        .alert(
            "无法添加",
            isPresented: .init(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })
        ) {
            Button("好") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    // MARK: 按钮们

    private var attachButton: some View {
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("图片", systemImage: "photo.on.rectangle")
            }
            .disabled(currentModel.map { !$0.acceptsImages } ?? false)

            Button {
                isPickingFiles = true
            } label: {
                Label("文件", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .padding(4)
                .glassEffect(in: .circle)
        }
        .tint(.primary)
        .accessibilityLabel("添加附件")
    }

    private var permissionMenu: some View {
        Menu {
            Picker(
                "权限",
                selection: Binding(
                    get: { chat.config.permission },
                    set: { mode in Task { await chat.setPermission(mode) } }
                )
            ) {
                ForEach(PermissionMode.allCases) { mode in
                    Label {
                        Text(mode.title)
                        Text(mode.subtitle)
                    } icon: {
                        Image(systemName: mode.symbolName)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: chat.config.permission.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .padding(4)
                .glassEffect(in: .circle)
        }
        .tint(.primary)
        .accessibilityLabel("权限：\(chat.config.permission.title)")
    }

    private var modelMenu: some View {
        Menu {
            Section("Kimi 订阅") {
                ForEach(app.models) { model in
                    Button {
                        let effort = model.efforts.contains(chat.config.effort ?? "")
                            ? chat.config.effort
                            : model.defaultEffort
                        Task { await chat.setModel(model, effort: effort) }
                    } label: {
                        if model.model == chat.config.modelID {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
            if let currentModel, !currentModel.efforts.isEmpty {
                Section("思考强度") {
                    ForEach(currentModel.efforts, id: \.self) { effort in
                        Button {
                            Task { await chat.setModel(currentModel, effort: effort) }
                        } label: {
                            if effort == chat.config.effort {
                                Label(effort.effortLabel, systemImage: "checkmark")
                            } else {
                                Text(effort.effortLabel)
                            }
                        }
                    }
                }
            }
        } label: {
            Text(modelLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 34)
        }
        .tint(.primary)
    }

    private var modelLabel: String {
        let name = currentModel?.name
            ?? chat.config.modelID.map { ($0 as NSString).lastPathComponent }
            ?? "模型"
        guard let effort = chat.config.effort, currentModel?.efforts.isEmpty == false else { return name }
        return "\(name)·\(effort.effortLabel)"
    }

    @ViewBuilder
    private var sendButton: some View {
        if chat.isBusy, !canSend {
            Button {
                Task { await chat.abort() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("停止")
        } else {
            Button {
                let text = draft
                draft = ""
                Task { await chat.send(text) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
    }

    // MARK: 图片

    /// 缩到长边 1600px 的 JPEG：隧道单请求上限 10 MiB，base64 还要再膨胀 1/3。
    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard
                let data = try? await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data),
                let jpeg = image.resized(maxSide: 1600).jpegData(compressionQuality: 0.8),
                let thumbnail = image.resized(maxSide: 160).jpegData(compressionQuality: 0.7)
            else { continue }
            chat.attachments.append(.image(jpeg: jpeg, thumbnail: thumbnail))
        }
    }

    /// 文件在选中时就读进内存（安全作用域 URL 离开这个回调就可能失效），发送时再上传。
    private func loadFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "读不了「\(url.lastPathComponent)」。"
                continue
            }
            guard data.count <= Self.maxFileBytes else {
                attachmentError = "「\(url.lastPathComponent)」超过 9 MB，远程控制传不了这么大的文件。"
                continue
            }
            let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            chat.attachments.append(.file(name: url.lastPathComponent, mediaType: mediaType, data: data))
        }
    }
}

// MARK: - 待发送的图片

private struct AttachmentStrip: View {
    let chat: ChatModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chat.attachments) { attachment in
                    tile(for: attachment)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                chat.attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("移除附件")
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private func tile(for attachment: Attachment) -> some View {
        switch attachment {
        case let .image(_, _, thumbnail):
            if let image = UIImage(data: thumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 12))
            }
        case let .file(_, name, _, data):
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Int64(data.count), format: .byteCount(style: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 150, height: 56, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        }
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
