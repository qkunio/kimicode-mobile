import SwiftUI

/// 一条历史消息的渲染。
///
/// 目标是"能看懂正在发生什么"：用户消息靠右，助手正文用 Markdown，
/// 思考和工具调用折叠起来，权限确认显示当时的结果。
struct TranscriptRow: View {
    let message: HistoryMessage

    var body: some View {
        switch message {
        case let .user(user):
            UserBubble(text: user.plainText)

        case let .assistant(assistant):
            AssistantBlock(text: assistant.text ?? "")

        case let .thinking(thinking):
            CollapsibleBlock(
                title: "思考",
                systemImage: "brain",
                tint: .purple,
                preview: thinking.text?.firstLine
            ) {
                Text(thinking.text ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case let .toolCall(call):
            ToolCallBlock(call: call)

        case let .interaction(interaction):
            InteractionBlock(interaction: interaction)

        case .turn, .step:
            // turn/step 是结构性标记，不单独占一行。
            EmptyView()

        case let .unknown(type, _):
            Label("未支持的消息：\(type)", systemImage: "questionmark.square.dashed")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 各种块

private struct UserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.22), in: .rect(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
    }
}

private struct AssistantBlock: View {
    let text: String

    var body: some View {
        // 助手正文是 Markdown。AttributedString 的 Markdown 解析支持行内语法
        // （粗体/行内代码/链接），表格和代码块留给后续里程碑做专门渲染。
        Text(attributed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ToolCallBlock: View {
    let call: HistoryMessage.ToolCall

    var body: some View {
        CollapsibleBlock(
            title: call.name,
            systemImage: symbolName,
            tint: call.status == "error" ? .red : .blue,
            preview: previewText,
            trailing: { statusIcon }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let input = call.input, !input.isNull {
                    LabeledBlock(title: "入参") {
                        Text(input.prettyDescription)
                    }
                }
                if let output = call.output, !output.isNull {
                    LabeledBlock(title: "输出") {
                        Text(output.stringValue ?? output.prettyDescription)
                    }
                }
            }
        }
    }

    private var symbolName: String {
        switch call.name.lowercased() {
        case "bash", "shell": "terminal"
        case "read": "doc.text"
        case "edit", "write", "multiedit": "square.and.pencil"
        case "glob", "grep", "search": "magnifyingglass"
        case "webfetch", "websearch": "globe"
        case "task": "person.2"
        default: "hammer"
        }
    }

    /// 折叠态那一行：命令/路径优先，退回整个入参的紧凑形式。
    private var previewText: String? {
        call.input?["command"]?.stringValue
            ?? call.input?["file_path"]?.stringValue
            ?? call.input?["path"]?.stringValue
            ?? call.input?["pattern"]?.stringValue
            ?? call.input?.compactDescription
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case "done", "completed":
            Image(systemName: "checkmark").foregroundStyle(.green)
        case "error", "failed":
            Image(systemName: "xmark.octagon").foregroundStyle(.red)
        case "running":
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }
}

private struct InteractionBlock: View {
    let interaction: HistoryMessage.Interaction

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(interaction.request?.action ?? interaction.request?.toolName ?? "权限确认")
                    .font(.caption)
                    .lineLimit(2)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var icon: String {
        switch interaction.status {
        case "approved": "checkmark.shield"
        case "rejected", "denied": "xmark.shield"
        default: "shield"
        }
    }

    private var tint: Color {
        switch interaction.status {
        case "approved": .green
        case "rejected", "denied": .red
        default: .orange
        }
    }

    private var statusText: String {
        switch interaction.status {
        case "approved": "已批准"
        case "rejected", "denied": "已拒绝"
        case "cancelled": "已取消"
        default: interaction.status ?? "等待中"
        }
    }
}

// MARK: - 可复用

private struct CollapsibleBlock<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let preview: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @State private var isExpanded = false

    init(
        title: String,
        systemImage: String,
        tint: Color,
        preview: String?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.preview = preview
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.caption.weight(.medium))
                    if let preview, !isExpanded {
                        Text(preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    trailing
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}

private struct LabeledBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                content
            }
        }
    }
}

extension String {
    var firstLine: String? {
        split(separator: "\n").first.map(String.init)
    }
}
