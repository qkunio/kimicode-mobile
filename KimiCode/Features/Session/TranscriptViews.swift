import SwiftUI

// 对话流的各个部件，结构与交互对照官方网页端（ChatPane / TurnFold / ActivityRun /
// ThinkingBlock / ToolDisclosure / 各 *Tool / WorkingIndicator），字号走系统动态字体：
//   正文 .body，工具行 / 思考 / 折叠头 .subheadline，时间等元信息 .caption。

/// 展开 / 收起的状态按 id 存在这里（官方存在 historyState 里），滚出屏幕再回来不丢。
@MainActor
@Observable
final class TranscriptUIState {
    private var open: [String: Bool] = [:]
    /// 进行中的一组「思考 + 工具」量出来的耗时，结束后显示在摘要尾部。
    var runDurations: [String: Double] = [:]
    var runStarts: [String: Date] = [:]

    func isOpen(_ key: String, default value: Bool) -> Bool { open[key] ?? value }
    func override(_ key: String) -> Bool? { open[key] }
    func set(_ key: String, _ value: Bool?) { open[key] = value }
}

// MARK: - 整条对话

struct ConversationList: View {
    let chat: ChatModel
    let ui: TranscriptUIState
    let confirmUndo: (UserEntry) -> Void

    var body: some View {
        let entries = chat.entries
        let liveID = liveEntryID(entries)
        let interruptedID = interruptedEntryID(entries)

        if chat.transcript.hasMoreOlder || chat.isLoadingOlder {
            LoadOlderRow(loading: chat.isLoadingOlder) {
                Task { await chat.loadOlder() }
            }
        }

        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            Group {
                switch entry.kind {
                case let .user(user):
                    UserTurnView(
                        entry: user,
                        canUndo: user.undoCount != nil && !chat.isWorking,
                        undo: { confirmUndo(user) }
                    )
                case let .compaction(compaction):
                    CompactionDivider(entry: compaction)
                case let .assistant(assistant):
                    AssistantMessageView(
                        entry: assistant,
                        ui: ui,
                        live: assistant.id == liveID,
                        streamingTail: assistant.id == liveID ? streamingTail(assistant) : nil,
                        showFooter: assistant.id != liveID && isLastOfRun(index, in: entries)
                    )
                    if assistant.id == interruptedID {
                        LabeledDivider(text: "已手动终止")
                            .padding(.top, 18)
                    }
                }
            }
            .padding(.top, index == 0 ? 0 : gap(for: entry))
            .id(entry.id)
        }

        ForEach(chat.optimisticPrompts) { prompt in
            OptimisticPromptRow(prompt: prompt) {
                Task { await chat.retry(prompt) }
            } discard: {
                chat.discard(prompt)
            }
            .padding(.top, 16)
        }

        if case let .failed(maxSteps, message, meta)? = chat.lastTurnEnd, !entries.isEmpty {
            TurnFailedCard(maxSteps: maxSteps, message: message, meta: meta) {
                Task { await chat.resume() }
            }
            .padding(.top, 12)
        }

        if chat.isCompacting {
            ActivityNotice(label: "正在压缩上下文…")
                .padding(.top, 12)
        }

        if chat.isWorking || !entries.isEmpty {
            WorkingIndicator(label: chat.isWorking ? workingLabel(entries) : nil)
                .padding(.top, 14)
        }
    }

    /// `g`：本轮在跑时，最后一条若是助手消息，它就是「活的」那条。
    private func liveEntryID(_ entries: [ChatEntry]) -> String? {
        guard chat.isWorking, case let .assistant(entry)? = entries.last?.kind else { return nil }
        return entry.id
    }

    /// `tc`：上一轮被手动终止，分隔线画在最后一条（有内容的）助手消息下面。
    private func interruptedEntryID(_ entries: [ChatEntry]) -> String? {
        guard chat.lastTurnEnd == .cancelled, case let .assistant(entry)? = entries.last?.kind,
              entry.hasContent else { return nil }
        return entry.id
    }

    /// `$t`：活消息里正在流式输出的块下标。刚结束的思考、等你确认的工具不算。
    private func streamingTail(_ entry: AssistantEntry) -> Int? {
        guard let last = entry.blocks.last else { return nil }
        if case let .thinking(item) = last, item.durationMs != nil { return nil }
        if case let .tool(tool) = last, tool.status == .running,
           chat.pendingApprovals.contains(where: { $0.toolCallID == tool.id })
            || chat.pendingQuestions.contains(where: { $0.toolCallID == tool.id }) {
            return nil
        }
        return entry.blocks.count - 1
    }

    private func isLastOfRun(_ index: Int, in entries: [ChatEntry]) -> Bool {
        guard index + 1 < entries.count else { return true }
        if case .assistant = entries[index + 1].kind { return false }
        return true
    }

    private func gap(for entry: ChatEntry) -> CGFloat {
        if case .assistant = entry.kind { return 10 }
        return 16
    }

    private func workingLabel(_ entries: [ChatEntry]) -> String {
        if let retry = chat.retry {
            return "模型请求失败，正在重试（第 \(retry.next)/\(retry.max) 次）…"
        }
        if case let .assistant(entry)? = entries.last?.kind, entry.hasContent {
            return "工作中…"
        }
        return "请求中…"
    }
}

private struct LoadOlderRow: View {
    let loading: Bool
    let load: () -> Void

    var body: some View {
        Group {
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更早的消息…")
                }
            } else {
                Button("加载更早的消息", action: load)
                    .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
        .onAppear { if !loading { load() } }
    }
}

// MARK: - 用户消息

struct UserTurnView: View {
    let entry: UserEntry
    let canUndo: Bool
    let undo: () -> Void

    @State private var expanded = false
    @State private var copied = false
    @State private var isClamped = false

    /// 官方 `Bq = 10`：超过 10 行折起来，给「展开 / 收起」。
    private static let clampLines = 10

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !entry.attachments.isEmpty {
                    FlowAttachments(attachments: entry.attachments)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .lineSpacing(3)
                        .lineLimit(expanded ? nil : Self.clampLines)
                        .textSelection(.enabled)
                        .background {
                            // 量一下完整高度，判断是否被截断。
                            Text(entry.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true).hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full in
                                    isClamped = full > UIFont.preferredFont(forTextStyle: .body).lineHeight * CGFloat(Self.clampLines) + 30
                                }
                        }
                    if isClamped {
                        Button {
                            withAnimation(.snappy) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 2) {
                                Text(expanded ? "收起" : "展开")
                                Image(systemName: "chevron.down")
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.userBubble, in: .rect(cornerRadius: 12))
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.88 }

            HStack(spacing: 6) {
                if !entry.text.isEmpty {
                    CopyButton(text: entry.text, copied: $copied)
                }
                if canUndo {
                    Button(action: undo) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("撤回消息")
                }
                if let createdAt = entry.createdAt {
                    MessageTime(date: createdAt)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct FlowAttachments: View {
    let attachments: [AttachmentRef]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments, id: \.self) { attachment in
                Label(attachment.name, systemImage: attachment.isImage ? "photo" : "doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.fill, in: .capsule)
            }
        }
    }
}

/// 官方 `FK`：今天只显示时间，昨天带「昨天」，更早带日期。
struct MessageTime: View {
    let date: Date

    var body: some View {
        Text(Self.format(date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day()) + " " + time
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day()) + " " + time
    }
}

private struct OptimisticPromptRow: View {
    let prompt: ChatModel.OptimisticPrompt
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                if prompt.attachmentCount > 0 {
                    Label("\(prompt.attachmentCount) 个附件", systemImage: "paperclip")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !prompt.text.isEmpty {
                    Text(prompt.text).lineSpacing(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Palette.userBubble, in: .rect(cornerRadius: 12))
            .opacity(prompt.failed ? 0.6 : 1)
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.88 }

            if prompt.failed {
                HStack(spacing: 12) {
                    Label("没发出去", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Palette.danger)
                    Button("重试", action: retry)
                    Button("丢弃", action: discard).foregroundStyle(.secondary)
                }
                .font(.caption)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - 助手消息

struct AssistantMessageView: View {
    let entry: AssistantEntry
    let ui: TranscriptUIState
    let live: Bool
    let streamingTail: Int?
    let showFooter: Bool

    @State private var copied = false

    var body: some View {
        let split = entry.foldSplit
        VStack(alignment: .leading, spacing: 0) {
            if !split.folded.isEmpty {
                TurnFoldView(
                    entry: entry,
                    items: split.folded,
                    ui: ui,
                    live: live,
                    streamingTail: streamingTail
                )
            }
            ForEach(Array(split.visible.enumerated()), id: \.element.id) { index, item in
                DisplayItemView(item: item, ui: ui, streamingTail: streamingTail)
                    .padding(.top, index == 0 && split.folded.isEmpty ? 0 : spacing(before: item))
            }
            if showFooter, entry.hasContent {
                footer
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spacing(before item: DisplayItem) -> CGFloat {
        if case .block(.tool, _) = item { return 6 }
        return 12
    }

    @ViewBuilder
    private var footer: some View {
        let text = entry.visibleText
        HStack(spacing: 6) {
            if let time = entry.endedAt ?? entry.createdAt.map({ $0.addingTimeInterval((entry.durationMs ?? 0) / 1000) }) {
                MessageTime(date: time)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CopyButton(text: text, copied: $copied)
            }
        }
    }
}

/// 助手消息里的一项：正文 / 思考 / 工具 / 通知 / 一组「思考 + 工具」。
struct DisplayItemView: View {
    let item: DisplayItem
    let ui: TranscriptUIState
    let streamingTail: Int?

    var body: some View {
        switch item {
        case let .block(block, index):
            BlockView(block: block, ui: ui, streaming: streamingTail == index)
        case let .activityRun(items):
            ActivityRunView(
                items: items,
                ui: ui,
                streaming: streamingTail != nil && items.last?.1 == streamingTail
            )
        }
    }
}

struct BlockView: View {
    let block: ChatBlock
    let ui: TranscriptUIState
    let streaming: Bool

    var body: some View {
        switch block {
        case let .text(_, text):
            MarkdownText(text: text)
        case let .thinking(item):
            ThinkingBlockView(item: item, ui: ui, streaming: streaming && item.durationMs == nil)
        case let .tool(tool):
            ToolLineView(tool: tool, ui: ui)
        case let .notification(_, title, body, failed):
            NotificationRow(title: title, bodyText: body, failed: failed)
        }
    }
}

// MARK: - 折叠：「已工作 X」

struct TurnFoldView: View {
    let entry: AssistantEntry
    let items: [DisplayItem]
    let ui: TranscriptUIState
    let live: Bool
    let streamingTail: Int?

    private var key: String { "fold:\(entry.id)" }
    private var streaming: Bool { streamingTail != nil }

    var body: some View {
        let open = streaming || ui.isOpen(key, default: false)
        VStack(alignment: .leading, spacing: 0) {
            if !streaming {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { ui.set(key, !open) }
                } label: {
                    HStack(spacing: 8) {
                        if live {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(label(now: context.date))
                            }
                        } else {
                            Text(label(now: nil))
                        }
                        Chevron(open: open)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 22)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        DisplayItemView(item: item, ui: ui, streamingTail: streamingTail)
                            .padding(.top, index == 0 ? (streaming ? 0 : 12) : spacing(before: item))
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: live) { _, isLive in
            // 本轮结束时收起（官方 live → settled 时 u = false）。
            if !isLive { ui.set(key, nil) }
        }
    }

    private func spacing(before item: DisplayItem) -> CGFloat {
        if case .block(.tool, _) = item { return 6 }
        return 12
    }

    /// `jAt`：结束了用 durationMs（或 endedAt - start），进行中用 now - start。
    private func label(now: Date?) -> String {
        let start = [entry.earliestThinkingStart, entry.createdAt].compactMap { $0 }.min()
        let ms: Double?
        if let now {
            ms = start.map { max(0, now.timeIntervalSince($0) * 1000) }
        } else if let duration = entry.durationMs {
            ms = max(0, duration)
        } else if let start, let end = entry.endedAt {
            ms = max(0, end.timeIntervalSince(start) * 1000)
        } else {
            ms = nil
        }
        if let ms, let text = Durations.format(ms), !text.isEmpty { return "已工作 \(text)" }
        return "工作过程"
    }
}

// MARK: - 一组「思考 + 工具」

struct ActivityRunView: View {
    let items: [(ChatBlock, Int)]
    let ui: TranscriptUIState
    let streaming: Bool

    private var key: String { "run:\(items.first?.0.id ?? "")" }

    private enum Status: Equatable { case running, error, done }

    private var tools: [ToolItem] {
        items.compactMap { if case let .tool(tool) = $0.0 { tool } else { nil } }
    }

    private var status: Status {
        if streaming || tools.contains(where: { $0.status == .running }) { return .running }
        if tools.contains(where: { $0.status == .error }) { return .error }
        return .done
    }

    /// `s`：流式中的思考，或最后一个还在跑的工具。
    private var current: ChatBlock? {
        if streaming, case .thinking? = items.last?.0 { return items.last?.0 }
        return items.last { if case let .tool(tool) = $0.0 { tool.status == .running } else { false } }?.0
    }

    var body: some View {
        let open = ui.override(key) ?? (status == .running)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { ui.set(key, !open) }
            } label: {
                HStack(spacing: 8) {
                    if status == .running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            summaryText(now: context.date)
                        }
                    } else {
                        summaryText(now: nil)
                    }
                    Chevron(open: open)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.0.id) { block, _ in
                        BlockView(
                            block: block,
                            ui: ui,
                            streaming: streaming && block.id == items.last?.0.id
                        )
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .onAppear { if status == .running, ui.runStarts[key] == nil { ui.runStarts[key] = startDate ?? .now } }
        .onChange(of: status) { old, new in
            // 开始跑时展开、跑完收起（官方：状态切换会覆盖手动开合）。
            ui.set(key, nil)
            if new == .running {
                ui.runStarts[key] = startDate ?? .now
                ui.runDurations[key] = nil
            } else if old == .running, let start = ui.runStarts[key] {
                ui.runDurations[key] = Date.now.timeIntervalSince(start) * 1000
                ui.runStarts[key] = nil
            }
        }
    }

    private var startDate: Date? {
        items.compactMap { if case let .thinking(item) = $0.0 { item.startedAt } else { nil } }.min()
    }

    private func summaryText(now: Date?) -> Text {
        let clauses: [ToolNames.Clause]
        if status == .running {
            let done = tools.filter { $0.status != .running && $0.id != current?.id }
            var live = ToolNames.liveSummary(current: current, done: done)
            if let now, let start = ui.runStarts[key] ?? startDate,
               let elapsed = Durations.format(now.timeIntervalSince(start) * 1000), !elapsed.isEmpty {
                live.append(.init(text: elapsed, faint: true))
            }
            clauses = live
        } else {
            clauses = ToolNames.settledSummary(tools, durationMs: ui.runDurations[key])
        }
        var result = Text("")
        for (index, clause) in clauses.enumerated() {
            if index > 0 { result = result + Text(" · ").foregroundStyle(.tertiary) }
            result = result + Text(clause.text).foregroundStyle(clause.faint ? .tertiary : .secondary)
        }
        return result
    }
}

// MARK: - 思考

struct ThinkingBlockView: View {
    let item: ThinkingItem
    let ui: TranscriptUIState
    let streaming: Bool

    private var key: String { "think:\(item.id)" }

    var body: some View {
        let open = ui.isOpen(key, default: false)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { ui.set(key, !open) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.footnote)
                        .frame(width: 20)
                    Text(streaming ? "思考中…" : "思考过程")
                        .modifier(Breathing(active: streaming))
                    if streaming, let start = item.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Durations.format(context.date.timeIntervalSince(start) * 1000) ?? "")
                                .foregroundStyle(.tertiary)
                        }
                    } else if let duration = item.durationMs, let text = Durations.format(duration), !text.isEmpty {
                        Text("· \(text)").foregroundStyle(.tertiary)
                    }
                    Chevron(open: open)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if open {
                IndentedBody {
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: streaming) { wasStreaming, isStreaming in
            // 思考结束时自动收起。
            if wasStreaming, !isStreaming { ui.set(key, false) }
        }
    }
}

// MARK: - 工具行

struct ToolLineView: View {
    let tool: ToolItem
    let ui: TranscriptUIState

    private var key: String { "tool:\(tool.id)" }

    var body: some View {
        let expandable = isExpandable
        let open = expandable && ui.isOpen(key, default: false)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(.snappy(duration: 0.25)) { ui.set(key, !open) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: ToolNames.symbol(tool.name))
                        .font(.footnote)
                        .frame(width: 20)
                    headline(open: open)
                    if expandable { Chevron(open: open) }
                    Spacer(minLength: 4)
                    statusView
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!expandable)

            if open {
                IndentedBody {
                    ToolBody(tool: tool)
                        .padding(.vertical, 6)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func headline(open: Bool) -> some View {
        switch tool.kind {
        case "edit", "multi_edit", "write":
            let path = ToolNames.summary(tool)
            let stats = ToolNames.diffStats(tool)
            HStack(spacing: 6) {
                Text(tool.kind == "write" ? "写入" : "编辑")
                if !open {
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if stats.added > 0 { Text("+\(stats.added)").foregroundStyle(Palette.diffAdd) }
                    if stats.removed > 0 { Text("−\(stats.removed)").foregroundStyle(Palette.diffDel) }
                }
                if let chip = ToolNames.chip(tool) { Text(chip).foregroundStyle(.tertiary) }
            }
        case "read":
            // 官方 ReadTool：文件名 + 目录（淡）+ 行号范围（淡）+ 行数。
            let parts = ToolNames.readParts(tool)
            HStack(spacing: 6) {
                Text("读取").layoutPriority(1)
                if let name = parts.name {
                    Text(name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                }
                if let dir = parts.dir {
                    Text(dir).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                if let range = parts.range {
                    Text(range).foregroundStyle(.tertiary).fixedSize()
                }
                if let chip = ToolNames.chip(tool) {
                    Text(chip).foregroundStyle(.tertiary).fixedSize()
                }
            }
        case "grep", "search":
            // 官方 GrepTool：模式 + 范围（淡）+ 结果数（淡）。
            let object = tool.input?.objectValue ?? [:]
            let pattern = ["pattern", "query", "regex"].lazy.compactMap { object[$0]?.stringValue }.first
            let scope = ["path", "glob", "include"].lazy.compactMap { object[$0]?.stringValue }.first
            HStack(spacing: 6) {
                Text(ToolNames.label(tool.name)).layoutPriority(1)
                if let pattern { Text(pattern).lineLimit(1) }
                if let scope { Text(scope).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                if let chip = ToolNames.chip(tool) { Text(chip).foregroundStyle(.tertiary).fixedSize() }
            }
        default:
            let subject = ToolNames.summary(tool)
            HStack(spacing: 6) {
                Text(ToolNames.label(tool.name))
                    .layoutPriority(1)
                if !subject.isEmpty {
                    Text(subject)
                        .lineLimit(1)
                        .truncationMode(tool.kind == "read" || tool.kind == "ls" ? .middle : .tail)
                }
                if let chip = ToolNames.chip(tool) {
                    Text(chip)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch tool.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .error:
            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.danger)
        case .cancelled:
            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        case .ok:
            EmptyView()
        }
    }

    /// 各工具「有没有可展开的内容」，与官方各 *Tool 的 expandable 条件一致。
    private var isExpandable: Bool {
        let hasOutput = !tool.output.isEmpty
        switch tool.kind {
        case "bash":
            return hasOutput || tool.status == .running || !ToolNames.summary(tool).isEmpty
        case "edit", "multi_edit", "write":
            return !ToolNames.diffLines(tool).isEmpty || hasOutput
        case "grep", "search":
            return tool.output.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case "read":
            return hasOutput
        default:
            let full = ToolNames.summary(tool, full: true)
            return hasOutput || (!full.isEmpty && full != ToolNames.summary(tool))
        }
    }
}

/// 工具展开后的面板（官方 ToolPanel：浅底、圆角 8、标题 + 复制、输出最多约 12 行可滚）。
private struct ToolBody: View {
    let tool: ToolItem

    @State private var copied = false

    var body: some View {
        switch tool.kind {
        case "edit", "multi_edit", "write":
            let lines = ToolNames.diffLines(tool)
            panel(
                title: ToolNames.summary(tool),
                meta: nil,
                copy: lines.isEmpty ? tool.output.joined(separator: "\n") : lines.map(diffPrefix).joined(separator: "\n")
            ) {
                if lines.isEmpty {
                    OutputLines(lines: tool.output, empty: "等待输出…")
                } else {
                    DiffLinesView(lines: lines)
                }
            }
        case "bash":
            let command = ToolNames.summary(tool)
            panel(title: tool.name.isEmpty ? "Bash" : tool.name, meta: tool.input?["cwd"]?.stringValue, copy: command) {
                OutputLines(lines: tool.output, empty: tool.status == .running ? "等待输出…" : "（无输出）")
            }
        case "grep":
            panel(title: nil, meta: nil, copy: nil) {
                GrepMatches(lines: tool.output)
            }
        case "read":
            panel(title: ToolNames.summary(tool), meta: nil, copy: tool.output.joined(separator: "\n")) {
                OutputLines(lines: tool.output, empty: "等待输出…")
            }
        default:
            let full = ToolNames.summary(tool, full: true)
            panel(title: nil, meta: nil, copy: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    if !full.isEmpty, full != ToolNames.summary(tool) {
                        Text(full)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    OutputLines(lines: tool.output, empty: tool.status == .running ? "等待输出…" : "（无输出）")
                }
            }
        }
    }

    private func diffPrefix(_ line: ToolNames.DiffLine) -> String {
        switch line.kind {
        case .add: "+" + line.text
        case .del: "-" + line.text
        case .context: " " + line.text
        case .hunk: line.text
        }
    }

    private func panel<Content: View>(
        title: String?,
        meta: String?,
        copy: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if title?.isEmpty == false || meta?.isEmpty == false || copy?.isEmpty == false {
                HStack(spacing: 8) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let meta, !meta.isEmpty {
                        Text(meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    if let copy, !copy.isEmpty {
                        CopyButton(text: copy, copied: $copied)
                            .padding(.vertical, -6)
                    }
                }
                .font(.subheadline)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: .rect(cornerRadius: 8))
    }
}

/// 官方 OutputPanel：等宽、最多约 12 行，超出在面板里滚。
private struct OutputLines: View {
    let lines: [String]
    let empty: String

    var body: some View {
        if lines.isEmpty {
            Text(empty)
                .font(.footnote)
                .italic()
                .foregroundStyle(.tertiary)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(lines.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 12 * 20)
            .fixedSize(horizontal: false, vertical: lines.count <= 12)
        }
    }
}

struct DiffLinesView: View {
    let lines: [ToolNames.DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Text(prefix(line)).foregroundStyle(color(line))
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .hunk ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    }
                    .font(.footnote.monospaced())
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line))
                }
            }
            .fixedSize()
            .textSelection(.enabled)
        }
        .frame(maxHeight: 16 * 20)
        .fixedSize(horizontal: false, vertical: lines.count <= 16)
    }

    private func prefix(_ line: ToolNames.DiffLine) -> String {
        switch line.kind {
        case .add: "+"
        case .del: "−"
        case .context, .hunk: " "
        }
    }

    private func color(_ line: ToolNames.DiffLine) -> Color {
        switch line.kind {
        case .add: Palette.diffAdd
        case .del: Palette.diffDel
        default: .secondary
        }
    }

    private func background(_ line: ToolNames.DiffLine) -> Color {
        switch line.kind {
        case .add: Palette.diffAdd.opacity(0.12)
        case .del: Palette.diffDel.opacity(0.12)
        default: .clear
        }
    }
}

private struct GrepMatches: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated()), id: \.offset) { _, line in
                    if let match = line.firstMatch(of: /^(.+?):(\d+)[:-](.*)$/) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(match.1):\(match.2)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(String(match.3).trimmingCharacters(in: .whitespaces))
                                .font(.footnote.monospaced())
                                .lineLimit(2)
                        }
                    } else {
                        Text(line).font(.footnote.monospaced())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 12 * 22)
    }
}

// MARK: - 其余部件

/// 展开内容左缩进，左边一条虚线（官方 `.tl-body-inner:before`）。
struct IndentedBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                DashedLine()
                    .stroke(Palette.line, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .frame(width: 1)
                    .padding(.leading, 9.75)
            }
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}

struct Chevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? 90 : 0))
    }
}

/// 进行中的文字轻轻呼吸（官方 `think-breathe` / `wi-breathe`，1.6s）。
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = active }
            .onChange(of: active) { _, value in dim = value }
    }
}

private struct NotificationRow: View {
    let title: String
    let bodyText: String
    let failed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle" : "bell")
                .font(.footnote)
                .foregroundStyle(failed ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary)
                if !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                }
            }
        }
        .font(.subheadline)
    }
}

/// 两边细线、中间一行字（「已手动终止」、上下文压缩）。
struct LabeledDivider<Label: View>: View {
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.line).frame(height: 0.5)
            label
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle().fill(Palette.line).frame(height: 0.5)
        }
    }
}

extension LabeledDivider where Label == Text {
    init(text: String) {
        self.init { Text(text) }
    }
}

private struct CompactionDivider: View {
    let entry: CompactionEntry

    @State private var isShowingSummary = false

    var body: some View {
        LabeledDivider {
            if entry.summary?.isEmpty == false {
                Button {
                    isShowingSummary = true
                } label: {
                    HStack(spacing: 8) {
                        Text(title)
                        Text("查看摘要").foregroundStyle(Palette.kimi)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
            }
        }
        .padding(.top, 2)
        .sheet(isPresented: $isShowingSummary) {
            NavigationStack {
                ScrollView {
                    MarkdownText(text: entry.summary ?? "")
                        .padding()
                }
                .navigationTitle("压缩摘要")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { isShowingSummary = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        let base = entry.auto ? "已自动压缩上下文" : "上下文已压缩"
        guard let before = entry.tokensBefore, let after = entry.tokensAfter else { return base }
        return base + "（\(Self.tokens(before)) → \(Self.tokens(after)) tokens）"
    }

    static func tokens(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(value)"
    }
}

/// 上一轮失败：红底卡片 + 「继续」（官方 `.turn-failed`）。
private struct TurnFailedCard: View {
    let maxSteps: Bool
    let message: String?
    let meta: String?
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Palette.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(maxSteps ? "达到本轮步数上限，对话已中断" : "模型请求失败，本轮对话已中断")
                    .font(.subheadline)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("继续", action: resume)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.dangerSoft, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.danger.opacity(0.3), lineWidth: 0.5))
    }
}

/// 转圈 + 一行字（官方 ActivityNotice）。
private struct ActivityNotice: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// 底部的 Kimi 小脸（官方 WorkingIndicator）：在跑时眨眼 + 呼吸的文字，空闲时只有脸。
struct WorkingIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 12) {
            KimiFace(animating: label != nil)
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
                    .modifier(Breathing(active: true))
            }
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

private struct KimiFace: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
            let phase = animating ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 : 0
            // 2.4s 一个周期：中段左右瞄一眼，末尾眨一下眼。
            let glance: CGFloat = phase > 0.35 && phase < 0.6 ? 2 : 0
            let blink: CGFloat = phase > 0.9 && phase < 0.96 ? 0.2 : 1
            RoundedRectangle(cornerRadius: 2.3)
                .fill(Palette.kimi)
                .frame(width: 24, height: 16)
                .overlay {
                    HStack(spacing: 6) {
                        eye(blink)
                        eye(blink)
                    }
                    .offset(x: 2.7 + glance, y: -2.8)
                }
        }
        .accessibilityHidden(true)
    }

    private func eye(_ scale: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: 3, height: 4.5)
            .scaleEffect(y: scale)
    }
}
