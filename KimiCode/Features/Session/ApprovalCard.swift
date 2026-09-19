import SwiftUI

/// 权限确认卡片，结构对照官方 ApprovalCard：
///   头部 = 提醒圆点 + 按类型的标题（「运行命令?」「应用修改?」…），可最小化；
///   中间 = 要批准的东西原样摆出来（命令 / 路径 / URL / 计划）；
///   底部 = 竖排满宽的按钮：批准 / 本会话内批准 / 拒绝 / 反馈。
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let resolve: (ApprovalDecisionBody) -> Void

    @State private var minimized = false
    @State private var isGivingFeedback = false
    @State private var feedback = ""
    @State private var busy = false
    @FocusState private var feedbackFocused: Bool

    private var block: ApprovalBlock { ApprovalBlock(approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !minimized {
                ScrollView {
                    preview
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)

                if isGivingFeedback {
                    TextField("说明拒绝原因…", text: $feedback, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .focused($feedbackFocused)
                        .padding(10)
                        .background(Palette.fill, in: .rect(cornerRadius: 12))
                        .onAppear { feedbackFocused = true }
                }
                actions
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 20))
        .disabled(busy)
        .animation(.snappy(duration: 0.22), value: minimized)
        .animation(.snappy(duration: 0.22), value: isGivingFeedback)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(.orange).frame(width: 6, height: 6).frame(width: 14, height: 14)
            Text(block.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if minimized, !block.peek.isEmpty {
                Text(block.peek)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                minimized.toggle()
            } label: {
                Image(systemName: minimized ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(minimized ? "展开" : "收起")
        }
    }

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch block.kind {
            case "shell":
                if let command = block.command {
                    CodeBox(text: command)
                }
                if let cwd = block.cwd {
                    field("工作目录：\(cwd)")
                }
                if let danger = block.danger {
                    Label("危险: \(danger)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Palette.danger)
                }
            case "diff":
                if let path = block.path { pathLine(path) }
                if !block.diff.isEmpty {
                    DiffLinesView(lines: block.diff)
                        .padding(10)
                        .background(Palette.fill, in: .rect(cornerRadius: 8))
                }
            case "file":
                if let path = block.path { pathLine(path) }
                if let content = block.content, !content.isEmpty {
                    CodeBox(text: content)
                }
            case "fileop":
                if let tool = block.tool { field("工具：\(tool)") }
                if let op = block.op { field("操作：\(op)") }
                if let path = block.path { field("路径：\(path)") }
                if let detail = block.detail { field(detail) }
            case "url":
                if let url = block.url { CodeBox(text: url) }
            case "search":
                if let query = block.query {
                    Text("查询").font(.caption).foregroundStyle(.secondary)
                    CodeBox(text: query)
                }
                if let scope = block.scope { field("范围：\(scope)") }
            case "invocation":
                if let name = block.name { CodeBox(text: name) }
                if let description = block.description { field(description) }
            case "todo":
                ForEach(Array(block.todos.enumerated()), id: \.offset) { _, item in
                    Label(item.title, systemImage: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.dotted" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                }
            case "plan_review":
                if let plan = block.plan {
                    MarkdownText(text: plan)
                        .padding(12)
                        .background(Palette.fill, in: .rect(cornerRadius: 12))
                } else if let path = block.path {
                    field("该计划未保存内联内容：\(path)")
                }
            default:
                if !block.summary.isEmpty {
                    CodeBox(text: block.summary)
                }
            }
        }
    }

    private func pathLine(_ path: String) -> some View {
        Text(path)
            .font(.subheadline.monospaced())
            .lineLimit(2)
            .truncationMode(.middle)
    }

    private func field(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if isGivingFeedback {
                HStack(spacing: 8) {
                    ActionButton("取消") {
                        isGivingFeedback = false
                        feedback = ""
                    }
                    ActionButton("提交并拒绝", primary: true) {
                        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                        decide(.init(
                            decision: "rejected",
                            feedback: text.isEmpty ? nil : text,
                            selectedLabel: block.kind == "plan_review" ? "Revise" : nil
                        ))
                    }
                }
            } else if block.kind == "plan_review" {
                if block.options.isEmpty {
                    ActionButton("修改") { isGivingFeedback = true }
                    ActionButton("拒绝并退出") {
                        decide(.init(decision: "rejected", selectedLabel: "Reject and Exit"))
                    }
                    ActionButton("批准 plan", primary: true) { decide(.approved()) }
                } else {
                    ForEach(block.options, id: \.self) { label in
                        ActionButton(label) { decide(.init(decision: "approved", selectedLabel: label)) }
                    }
                }
            } else {
                ActionButton("批准", primary: true) { decide(.approved()) }
                ActionButton("本会话内批准") { decide(.approved(forSession: true)) }
                ActionButton("拒绝") { decide(.rejected()) }
                ActionButton("反馈") { isGivingFeedback = true }
            }
        }
    }

    private func decide(_ decision: ApprovalDecisionBody) {
        busy = true
        resolve(decision)
    }
}

/// 从 `tool_input_display` 解出官方的 block（移植网页端 `PJ`）：
/// 服务端的 kind（command / file_io / url_fetch / agent_call …）归并成卡片类型。
private struct ApprovalBlock {
    var kind = "generic"
    var command: String?
    var cwd: String?
    var danger: String?
    var path: String?
    var content: String?
    var diff: [ToolNames.DiffLine] = []
    var op: String?
    var detail: String?
    var tool: String?
    var url: String?
    var query: String?
    var scope: String?
    var name: String?
    var description: String?
    var plan: String?
    var todos: [(title: String, status: String)] = []
    var options: [String] = []
    var summary: String

    init(_ approval: ApprovalRequest) {
        let display = approval.toolInputDisplay ?? .object([:])
        func string(_ key: String) -> String? {
            guard let value = display[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        let raw = string("kind") ?? ""
        summary = approval.action

        switch raw {
        case "diff":
            kind = "diff"
            path = string("path")
            if let lines = display["diff"]?.arrayValue {
                diff = lines.compactMap(Self.diffLine)
            } else if let before = string("old_text") ?? string("before"), let after = string("new_text") ?? string("after") {
                diff = Self.diff(before, after)
            }
        case "file_io":
            path = string("path")
            let operation = string("operation") ?? ""
            if operation == "write", let text = string("content") {
                kind = "file"
                content = text
            } else if operation == "edit", let before = string("before"), let after = string("after") {
                kind = "diff"
                diff = Self.diff(before, after)
            } else {
                kind = "fileop"
                op = operation.isEmpty ? raw : operation
                detail = string("detail")
                tool = approval.toolName
            }
        case "shell", "command":
            kind = "shell"
            command = string("command") ?? approval.action
            cwd = string("cwd")
            danger = string("danger")
        case "file_content", "file":
            kind = "file"
            path = string("path")
            content = string("content")
        case "file_op", "fileop":
            kind = "fileop"
            op = string("operation") ?? string("op") ?? raw
            path = string("path")
            detail = string("detail")
            tool = approval.toolName
        case "url_fetch", "url":
            kind = "url"
            url = string("url") ?? approval.action
        case "search":
            kind = "search"
            query = string("query") ?? approval.action
            scope = string("scope")
        case "invocation", "agent_call", "skill_call":
            kind = "invocation"
            name = string("name") ?? approval.toolName
            description = string("description")
        case "todo", "todo_list":
            kind = "todo"
            todos = (display["items"]?.arrayValue ?? []).map {
                ($0["title"]?.stringValue ?? "", $0["status"]?.stringValue ?? "pending")
            }
        case "plan_review":
            kind = "plan_review"
            plan = string("plan")
            path = string("path")
            options = (display["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }.filter { !$0.isEmpty }
        default:
            kind = "generic"
        }
    }

    private static func diffLine(_ value: JSONValue) -> ToolNames.DiffLine? {
        let text = value["text"]?.stringValue ?? value["content"]?.stringValue ?? value.stringValue ?? ""
        switch value["type"]?.stringValue ?? value["kind"]?.stringValue {
        case "add", "added", "insert": return .init(kind: .add, text: text)
        case "del", "delete", "deleted", "remove", "removed": return .init(kind: .del, text: text)
        case "hunk": return .init(kind: .hunk, text: text)
        default: return .init(kind: .context, text: text)
        }
    }

    private static func diff(_ before: String, _ after: String) -> [ToolNames.DiffLine] {
        let tool = ToolItem(
            id: "", name: "edit",
            input: .object(["old_string": .string(before), "new_string": .string(after)]),
            output: [], status: .ok
        )
        return ToolNames.diffLines(tool)
    }

    /// 官方 `approval.title.*`。
    var title: String {
        switch kind {
        case "shell": return "运行命令?"
        case "diff": return "应用修改?"
        case "file": return "写入文件?"
        case "fileop":
            let verbs = ["read": "读取", "grep": "搜索", "glob": "查找", "edit": "编辑", "write": "写入", "delete": "删除"]
            if let op, let verb = verbs[op], let path {
                return "允许 Kimi Code \(verb) \((path as NSString).lastPathComponent)"
            }
            return "文件操作?"
        case "url": return "抓取 URL?"
        case "search": return "搜索?"
        case "invocation": return "调用?"
        case "todo": return "更新 todo?"
        case "plan_review": return "按这份 plan 开始实现?"
        case "browser": return "浏览器操作"
        default: return "批准操作?"
        }
    }

    /// 最小化时头部露出的一句（官方 `j`）。
    var peek: String {
        switch kind {
        case "diff", "file", "fileop": path ?? ""
        case "shell": command ?? ""
        case "url": url ?? ""
        case "search": query ?? ""
        case "invocation": name ?? ""
        case "generic": summary
        default: ""
        }
    }
}

private struct CodeBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Palette.fill, in: .rect(cornerRadius: 8))
    }
}

/// 卡片底部满宽按钮，最小高度 46（官方手机端 `.abtns > .cbtn`）。
struct ActionButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.primary = primary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(primary ? .semibold : .regular))
                .foregroundStyle(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    primary ? AnyShapeStyle(Palette.kimi) : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: .rect(cornerRadius: 12)
                )
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 提问

/// 提问卡片（官方 QuestionCard）：一题一页，单选 / 多选 / 「其他」，推荐项预先选中。
struct QuestionCard: View {
    let request: QuestionRequest
    let answer: ([String: QuestionAnswer]) -> Void
    let dismiss: () -> Void

    @State private var page = 0
    @State private var answers: [String: QuestionAnswer] = [:]
    @State private var otherTexts: [String: String] = [:]
    @State private var minimized = false
    @State private var busy = false
    @FocusState private var otherFocused: Bool

    private var question: QuestionRequest.Question? {
        request.questions.indices.contains(page) ? request.questions[page] : request.questions.first
    }

    private var allAnswered: Bool {
        request.questions.allSatisfy { answers[$0.id]?.isAnswered == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 6, height: 6).frame(width: 14, height: 14)
                Text(question?.header ?? "提问")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if request.questions.count > 1 {
                    Text("\(page + 1)/\(request.questions.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Button {
                    minimized.toggle()
                } label: {
                    Image(systemName: minimized ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if !minimized, let question {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.question)
                            .font(.body.weight(.medium))
                        if let body = question.body, !body.isEmpty {
                            MarkdownText(text: body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 6) {
                            ForEach(question.options) { option in
                                optionRow(option, in: question)
                            }
                            if question.allowOther {
                                otherRow(question)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    if request.questions.count > 1 {
                        HStack(spacing: 8) {
                            ActionButton("上一题") { page = max(0, page - 1) }
                                .disabled(page == 0)
                                .opacity(page == 0 ? 0.5 : 1)
                            ActionButton("下一题") { page = min(request.questions.count - 1, page + 1) }
                                .disabled(page >= request.questions.count - 1)
                                .opacity(page >= request.questions.count - 1 ? 0.5 : 1)
                        }
                    }
                    HStack(spacing: 8) {
                        ActionButton("放弃") {
                            busy = true
                            dismiss()
                        }
                        ActionButton("提交", primary: true) {
                            busy = true
                            answer(answers)
                        }
                        .disabled(!allAnswered)
                        .opacity(allAnswered ? 1 : 0.5)
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 20))
        .disabled(busy)
        .onAppear(perform: preselectRecommended)
        .onChange(of: request.questionID) {
            page = 0
            answers = [:]
            otherTexts = [:]
            preselectRecommended()
        }
    }

    private func optionRow(_ option: QuestionRequest.Option, in question: QuestionRequest.Question) -> some View {
        let selected = isSelected(option.id, in: question)
        return Button {
            toggle(option.id, in: question)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect
                    ? (selected ? "checkmark.square.fill" : "square")
                    : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.kimi) : AnyShapeStyle(.tertiary))
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .foregroundStyle(.primary)
                        if option.recommended {
                            Text("推荐")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Palette.kimi)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Palette.kimi.opacity(0.12), in: .capsule)
                        }
                    }
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? Palette.kimi.opacity(0.08) : Palette.fill, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func otherRow(_ question: QuestionRequest.Question) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasOther(question) ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                : (question.multiSelect ? "square" : "circle"))
                .foregroundStyle(hasOther(question) ? AnyShapeStyle(Palette.kimi) : AnyShapeStyle(.tertiary))
            TextField(
                question.otherLabel ?? "其他",
                text: Binding(
                    get: { otherTexts[question.id] ?? "" },
                    set: { text in
                        otherTexts[question.id] = text
                        setOther(text, in: question)
                    }
                ),
                prompt: Text("\(question.otherLabel ?? "其他")：说说你的想法…"),
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .focused($otherFocused)
        }
        .padding(10)
        .background(hasOther(question) ? Palette.kimi.opacity(0.08) : Palette.fill, in: .rect(cornerRadius: 12))
    }

    // MARK: 选择逻辑（官方 `_` / `x` / `M`）

    private func isSelected(_ optionID: String, in question: QuestionRequest.Question) -> Bool {
        switch answers[question.id] {
        case let .single(id)?: id == optionID
        case let .multi(ids)?: ids.contains(optionID)
        case let .multiWithOther(ids, _)?: ids.contains(optionID)
        default: false
        }
    }

    private func hasOther(_ question: QuestionRequest.Question) -> Bool {
        switch answers[question.id] {
        case .other?, .multiWithOther?: true
        default: false
        }
    }

    private func toggle(_ optionID: String, in question: QuestionRequest.Question) {
        if question.multiSelect {
            var ids: [String]
            var other = ""
            switch answers[question.id] {
            case let .multi(existing)?: ids = existing
            case let .multiWithOther(existing, text)?: ids = existing; other = text
            default: ids = []
            }
            if let index = ids.firstIndex(of: optionID) { ids.remove(at: index) } else { ids.append(optionID) }
            answers[question.id] = other.isEmpty ? .multi(ids) : .multiWithOther(ids, other)
        } else if case let .single(id)? = answers[question.id], id == optionID {
            answers[question.id] = nil
        } else {
            answers[question.id] = .single(optionID)
            otherFocused = false
        }
    }

    private func setOther(_ text: String, in question: QuestionRequest.Question) {
        if question.multiSelect {
            let ids: [String] = switch answers[question.id] {
            case let .multi(existing)?: existing
            case let .multiWithOther(existing, _)?: existing
            default: []
            }
            answers[question.id] = .multiWithOther(ids, text)
        } else {
            answers[question.id] = .other(text)
        }
    }

    /// 官方 `N()`：没答的题，把推荐项预先选上。
    private func preselectRecommended() {
        for question in request.questions where answers[question.id] == nil {
            let recommended = question.options.filter(\.recommended)
            guard !recommended.isEmpty else { continue }
            answers[question.id] = question.multiSelect ? .multi(recommended.map(\.id)) : .single(recommended[0].id)
        }
    }
}
