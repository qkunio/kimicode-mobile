import Foundation

// MARK: - Transcript 模型
//
// 与官方网页端一致：对话正文走 transcript 通道，而不是 `/history`。
//   - 首屏 `GET /sessions/{id}/transcript?agent_id=main&page_size=N`（按轮分页）
//   - 之后 WS `subscribe_v2 {transcript:{main:"delta"}, transcript_since}` 推 `transcript.reset/ops`
//   - 本地按 `packages/transcript/src/ops/apply.ts` 的语义应用增量（逐字流式）
//
// 线上格式：外层是 snake_case（`agent_id`/`has_more`），items/ops 里面是 camelCase。
// 字段大多可选 —— 没见过的 frame/op 类型原样忽略，不让整条流断。

struct TranscriptFrame: Decodable, Sendable, Equatable {
    let kind: String
    let frameId: String
    // text
    var role: String?
    var text: String?
    var attachmentIds: [String]?
    var taskId: String?
    var promptIds: [String]?
    var origin: JSONValue?
    // tool
    var toolCallId: String?
    var name: String?
    var state: String?
    var input: JSONValue?
    var output: JSONValue?
    var display: JSONValue?
    var error: String?
    var inputText: String?
    var progress: JSONValue?
    var approvalId: String?
    var agentRefs: JSONValue?
    // notice
    var level: String?
    var message: String?
}

struct TranscriptStep: Decodable, Sendable, Equatable {
    let stepId: String
    let turnId: String
    var ordinal: Int
    var state: String
    var frames: [TranscriptFrame]
    var startedAt: String?
    var endedAt: String?
    var endReason: String?
    var endMessage: String?

    enum CodingKeys: String, CodingKey {
        case stepId, turnId, ordinal, state, frames, startedAt, endedAt, endReason, endMessage
    }

    init(stepId: String, turnId: String, ordinal: Int, state: String, frames: [TranscriptFrame]) {
        self.stepId = stepId
        self.turnId = turnId
        self.ordinal = ordinal
        self.state = state
        self.frames = frames
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepId = try c.decode(String.self, forKey: .stepId)
        turnId = try c.decodeIfPresent(String.self, forKey: .turnId) ?? ""
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "running"
        frames = (try? c.decodeIfPresent([Lossy<TranscriptFrame>].self, forKey: .frames))?
            .compactMap(\.value) ?? []
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(String.self, forKey: .endedAt)
        endReason = try? c.decodeIfPresent(String.self, forKey: .endReason)
        endMessage = try? c.decodeIfPresent(String.self, forKey: .endMessage)
    }
}

struct TranscriptTurn: Decodable, Sendable, Equatable {
    let turnId: String
    var triggerPromptId: String?
    var ordinal: Int
    var state: String
    var origin: JSONValue?
    var prompt: String?
    var attachmentIds: [String]?
    var steps: [TranscriptStep]
    var startedAt: String?
    var endedAt: String?
    var durationMs: Double?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case turnId, triggerPromptId, ordinal, state, origin, prompt, attachmentIds, steps
        case startedAt, endedAt, durationMs, error
    }

    init(skeleton turnId: String) {
        self.turnId = turnId
        ordinal = TranscriptTurn.ordinal(of: turnId)
        state = "running"
        steps = []
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnId = try c.decode(String.self, forKey: .turnId)
        triggerPromptId = try? c.decodeIfPresent(String.self, forKey: .triggerPromptId)
        ordinal = (try? c.decodeIfPresent(Int.self, forKey: .ordinal)) ?? TranscriptTurn.ordinal(of: turnId)
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "running"
        origin = try? c.decodeIfPresent(JSONValue.self, forKey: .origin)
        prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
        attachmentIds = try? c.decodeIfPresent([String].self, forKey: .attachmentIds)
        steps = (try? c.decodeIfPresent([Lossy<TranscriptStep>].self, forKey: .steps))?.compactMap(\.value) ?? []
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try? c.decodeIfPresent(String.self, forKey: .endedAt)
        durationMs = try? c.decodeIfPresent(Double.self, forKey: .durationMs)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    /// turnId 形如 `t_12` / `12`，取末尾数字当序号（与 `turnOrdinal` 一致）。
    static func ordinal(of turnId: String) -> Int {
        Int(turnId.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
    }

    /// 触发这一轮的来源（`origin.payload ?? origin`）。
    var originKind: String? {
        (origin?["payload"] ?? origin)?["kind"]?.stringValue
    }
}

struct TranscriptMarker: Decodable, Sendable, Equatable {
    let markerId: String
    let marker: String
    var payload: JSONValue?
    var at: String?
}

struct TranscriptTaskRef: Decodable, Sendable, Equatable {
    let refId: String
    let taskId: String
    var at: String?
}

enum TranscriptItem: Decodable, Sendable, Equatable {
    case turn(TranscriptTurn)
    case marker(TranscriptMarker)
    case taskref(TranscriptTaskRef)

    var id: String {
        switch self {
        case let .turn(turn): turn.turnId
        case let .marker(marker): marker.markerId
        case let .taskref(ref): ref.refId
        }
    }

    private enum Keys: String, CodingKey { case kind }

    init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
        switch kind {
        case "turn": self = .turn(try TranscriptTurn(from: decoder))
        case "marker": self = .marker(try TranscriptMarker(from: decoder))
        case "taskref": self = .taskref(try TranscriptTaskRef(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: kind))
        }
    }
}

struct TranscriptInteraction: Decodable, Sendable, Equatable {
    let interactionId: String
    var interactionKind: String?
    var toolCallId: String?
    var state: String
    var request: JSONValue?
    var response: JSONValue?
}

struct TranscriptAttachment: Decodable, Sendable, Equatable {
    let attachmentId: String
    var mediaType: String?
    var name: String?
    var size: Int?
    var source: JSONValue?
}

struct TranscriptPrompt: Decodable, Sendable, Equatable {
    let promptId: String
    var status: String?
    var content: JSONValue?
    var createdAt: String?
}

struct TranscriptTask: Decodable, Sendable, Equatable {
    let taskId: String
    var kind: String?
    var state: String?
    var description: String?
    var agentId: String?
    var outputTail: String?
}

/// 解码失败的元素跳过，别让一个没见过的 frame 毁掉整页。
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - 增量操作

enum TranscriptAppendTarget: Sendable, Equatable {
    case frame(turnId: String, stepId: String, frameId: String)
    case task(taskId: String)
}

enum TranscriptOp: Decodable, Sendable {
    case reset(TranscriptSnapshot)
    case turnUpsert(TranscriptTurn)
    case stepUpsert(turnId: String, step: TranscriptStep)
    case frameUpsert(turnId: String, stepId: String, frame: TranscriptFrame)
    case append(target: TranscriptAppendTarget, offset: Int, text: String)
    case itemUpsert(TranscriptItem, beforeTurn: Int?)
    case taskUpsert(TranscriptTask)
    case interactionUpsert(TranscriptInteraction)
    case attachmentUpsert(TranscriptAttachment)
    case promptUpsert(TranscriptPrompt)
    case metaMerge(JSONValue)
    case itemsRemove([String])
    case other(String)

    private enum Keys: String, CodingKey {
        case op, snapshot, turn, turnId, step, stepId, frame, target, offset, text
        case item, beforeTurn, task, interaction, attachment, prompt, meta, ids
    }

    private struct Target: Decodable {
        let type: String
        let turnId: String?
        let stepId: String?
        let frameId: String?
        let taskId: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "reset":
            self = .reset(try c.decode(TranscriptSnapshot.self, forKey: .snapshot))
        case "turn.upsert":
            self = .turnUpsert(try c.decode(TranscriptTurn.self, forKey: .turn))
        case "step.upsert":
            self = .stepUpsert(
                turnId: try c.decode(String.self, forKey: .turnId),
                step: try c.decode(TranscriptStep.self, forKey: .step)
            )
        case "frame.upsert":
            self = .frameUpsert(
                turnId: try c.decode(String.self, forKey: .turnId),
                stepId: try c.decode(String.self, forKey: .stepId),
                frame: try c.decode(TranscriptFrame.self, forKey: .frame)
            )
        case "append":
            let target = try c.decode(Target.self, forKey: .target)
            let resolved: TranscriptAppendTarget
            if target.type == "task", let taskId = target.taskId {
                resolved = .task(taskId: taskId)
            } else if let turnId = target.turnId, let stepId = target.stepId, let frameId = target.frameId {
                resolved = .frame(turnId: turnId, stepId: stepId, frameId: frameId)
            } else {
                self = .other(op)
                return
            }
            self = .append(
                target: resolved,
                offset: try c.decode(Int.self, forKey: .offset),
                text: try c.decode(String.self, forKey: .text)
            )
        case "marker.upsert", "taskref.upsert":
            self = .itemUpsert(
                try c.decode(TranscriptItem.self, forKey: .item),
                beforeTurn: try? c.decodeIfPresent(Int.self, forKey: .beforeTurn)
            )
        case "task.upsert":
            self = .taskUpsert(try c.decode(TranscriptTask.self, forKey: .task))
        case "interaction.upsert":
            self = .interactionUpsert(try c.decode(TranscriptInteraction.self, forKey: .interaction))
        case "attachment.upsert":
            self = .attachmentUpsert(try c.decode(TranscriptAttachment.self, forKey: .attachment))
        case "prompt.upsert":
            self = .promptUpsert(try c.decode(TranscriptPrompt.self, forKey: .prompt))
        case "meta.merge":
            self = .metaMerge(try c.decode(JSONValue.self, forKey: .meta))
        case "items.remove":
            self = .itemsRemove(try c.decode([String].self, forKey: .ids))
        default:
            self = .other(op)
        }
    }
}

/// `reset` 里的快照（camelCase）。
struct TranscriptSnapshot: Decodable, Sendable {
    var items: [TranscriptItem]
    var tasks: [TranscriptTask]
    var interactions: [TranscriptInteraction]
    var attachments: [TranscriptAttachment]
    var prompts: [TranscriptPrompt]
    var meta: JSONValue?
    var hasMoreOlder: Bool?

    enum CodingKeys: String, CodingKey {
        case items, tasks, interactions, attachments, prompts, meta, hasMoreOlder
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([Lossy<TranscriptItem>].self, forKey: .items))?.compactMap(\.value) ?? []
        tasks = (try? c.decodeIfPresent([Lossy<TranscriptTask>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        interactions = (try? c.decodeIfPresent([Lossy<TranscriptInteraction>].self, forKey: .interactions))?
            .compactMap(\.value) ?? []
        attachments = (try? c.decodeIfPresent([Lossy<TranscriptAttachment>].self, forKey: .attachments))?
            .compactMap(\.value) ?? []
        prompts = (try? c.decodeIfPresent([Lossy<TranscriptPrompt>].self, forKey: .prompts))?
            .compactMap(\.value) ?? []
        meta = try? c.decodeIfPresent(JSONValue.self, forKey: .meta)
        hasMoreOlder = try? c.decodeIfPresent(Bool.self, forKey: .hasMoreOlder)
    }
}

/// `GET /sessions/{id}/transcript` 的响应（外层 snake_case）。
struct TranscriptPage: Decodable, Sendable {
    var items: [TranscriptItem]
    var tasks: [TranscriptTask]
    var interactions: [TranscriptInteraction]
    var attachments: [TranscriptAttachment]
    var prompts: [TranscriptPrompt]
    var meta: JSONValue?
    var hasMore: Bool
    var seq: Int?

    enum CodingKeys: String, CodingKey {
        case items, tasks, interactions, attachments, prompts, meta, seq
        case hasMore = "has_more"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([Lossy<TranscriptItem>].self, forKey: .items))?.compactMap(\.value) ?? []
        tasks = (try? c.decodeIfPresent([Lossy<TranscriptTask>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        interactions = (try? c.decodeIfPresent([Lossy<TranscriptInteraction>].self, forKey: .interactions))?
            .compactMap(\.value) ?? []
        attachments = (try? c.decodeIfPresent([Lossy<TranscriptAttachment>].self, forKey: .attachments))?
            .compactMap(\.value) ?? []
        prompts = (try? c.decodeIfPresent([Lossy<TranscriptPrompt>].self, forKey: .prompts))?
            .compactMap(\.value) ?? []
        meta = try? c.decodeIfPresent(JSONValue.self, forKey: .meta)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
    }
}

/// WS 推来的 `transcript.reset` / `transcript.ops` 的 payload。
enum TranscriptWireEvent: Decodable, Sendable {
    case reset(agentId: String, snapshot: TranscriptSnapshot, hasMoreOlder: Bool, seq: Int?)
    case ops(agentId: String, ops: [TranscriptOp], seq: Int?)

    private enum Keys: String, CodingKey {
        case type, snapshot, ops, seq
        case agentId = "agent_id"
        case hasMoreOlder = "has_more_older"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        let agentId = (try? c.decodeIfPresent(String.self, forKey: .agentId)) ?? "main"
        let seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        if type == "transcript.reset" {
            self = .reset(
                agentId: agentId,
                snapshot: try c.decode(TranscriptSnapshot.self, forKey: .snapshot),
                hasMoreOlder: (try? c.decodeIfPresent(Bool.self, forKey: .hasMoreOlder)) ?? false,
                seq: seq
            )
        } else {
            let ops = try c.decode([Lossy<TranscriptOp>].self, forKey: .ops).compactMap(\.value)
            self = .ops(agentId: agentId, ops: ops, seq: seq)
        }
    }
}

// MARK: - 本地状态机（移植 apply.ts）

struct TranscriptState: Sendable {
    var items: [TranscriptItem] = []
    var tasks: [String: TranscriptTask] = [:]
    var interactions: [String: TranscriptInteraction] = [:]
    var attachments: [String: TranscriptAttachment] = [:]
    var prompts: [String: TranscriptPrompt] = [:]
    var meta: [String: JSONValue] = [:]
    var hasMoreOlder = false
    /// 最后应用到的 ops 批次序号，断线续传时放进 `transcript_since`。
    var seq: Int?

    init() {}

    init(page: TranscriptPage) {
        items = page.items
        hasMoreOlder = page.hasMore
        seq = page.seq
        meta = page.meta?.objectValue ?? [:]
        merge(tasks: page.tasks, interactions: page.interactions, attachments: page.attachments, prompts: page.prompts)
    }

    init(snapshot: TranscriptSnapshot, hasMoreOlder: Bool, seq: Int?) {
        items = snapshot.items
        self.hasMoreOlder = snapshot.hasMoreOlder ?? hasMoreOlder
        self.seq = seq
        meta = snapshot.meta?.objectValue ?? [:]
        merge(
            tasks: snapshot.tasks,
            interactions: snapshot.interactions,
            attachments: snapshot.attachments,
            prompts: snapshot.prompts
        )
    }

    private mutating func merge(
        tasks: [TranscriptTask],
        interactions: [TranscriptInteraction],
        attachments: [TranscriptAttachment],
        prompts: [TranscriptPrompt]
    ) {
        for task in tasks { self.tasks[task.taskId] = task }
        for interaction in interactions { self.interactions[interaction.interactionId] = interaction }
        for attachment in attachments { self.attachments[attachment.attachmentId] = attachment }
        for prompt in prompts { self.prompts[prompt.promptId] = prompt }
    }

    /// 「加载更早的消息」：把更早一页插到前面。
    mutating func prepend(older page: TranscriptPage) {
        let known = Set(items.map(\.id))
        items = page.items.filter { !known.contains($0.id) } + items
        hasMoreOlder = page.hasMore
        merge(tasks: page.tasks, interactions: page.interactions, attachments: page.attachments, prompts: page.prompts)
    }

    var turns: [TranscriptTurn] {
        items.compactMap { if case let .turn(turn) = $0 { turn } else { nil } }
    }

    // MARK: apply

    /// 应用一条 op。返回 false 表示接不上（append 的 offset 对不齐），调用方要全量重拉。
    @discardableResult
    mutating func apply(_ op: TranscriptOp) -> Bool {
        switch op {
        case let .reset(snapshot):
            self = TranscriptState(snapshot: snapshot, hasMoreOlder: snapshot.hasMoreOlder ?? false, seq: seq)
        case let .turnUpsert(header):
            if let index = turnIndex(header.turnId), case let .turn(existing) = items[index] {
                var next = header
                next.steps = existing.steps
                items[index] = .turn(next)
            } else {
                insert(turn: header)
            }
        case let .stepUpsert(turnId, header):
            updateTurn(turnId) { turn in
                if let index = turn.steps.firstIndex(where: { $0.stepId == header.stepId }) {
                    var next = header
                    next.frames = turn.steps[index].frames
                    turn.steps[index] = next
                } else {
                    turn.steps.append(header)
                    turn.steps.sort { $0.ordinal < $1.ordinal }
                }
            }
        case let .frameUpsert(turnId, stepId, frame):
            updateTurn(turnId) { turn in
                if let index = turn.steps.firstIndex(where: { $0.stepId == stepId }) {
                    if let f = turn.steps[index].frames.firstIndex(where: { $0.frameId == frame.frameId }) {
                        turn.steps[index].frames[f] = frame
                    } else {
                        turn.steps[index].frames.append(frame)
                    }
                } else {
                    let ordinal = Int(stepId.dropFirst(turnId.count + 1)) ?? 0
                    turn.steps.append(
                        TranscriptStep(stepId: stepId, turnId: turnId, ordinal: ordinal, state: "running", frames: [frame])
                    )
                    turn.steps.sort { $0.ordinal < $1.ordinal }
                }
            }
        case let .append(target, offset, text):
            return applyAppend(target: target, offset: offset, chunk: text)
        case let .itemUpsert(item, beforeTurn):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else if let beforeTurn,
                      let at = items.firstIndex(where: { if case let .turn(t) = $0 { t.ordinal >= beforeTurn } else { false } }) {
                items.insert(item, at: at)
            } else {
                items.append(item)
            }
        case let .taskUpsert(task):
            tasks[task.taskId] = task
        case let .interactionUpsert(interaction):
            interactions[interaction.interactionId] = interaction
        case let .attachmentUpsert(attachment):
            attachments[attachment.attachmentId] = attachment
        case let .promptUpsert(prompt):
            prompts[prompt.promptId] = prompt
        case let .metaMerge(patch):
            mergeMeta(patch)
        case let .itemsRemove(ids):
            let drop = Set(ids)
            items.removeAll { drop.contains($0.id) }
        case .other:
            break
        }
        return true
    }

    private func turnIndex(_ turnId: String) -> Int? {
        items.firstIndex { if case let .turn(turn) = $0 { turn.turnId == turnId } else { false } }
    }

    private mutating func insert(turn: TranscriptTurn) {
        let at = items.firstIndex { if case let .turn(t) = $0 { t.ordinal > turn.ordinal } else { false } }
        items.insert(.turn(turn), at: at ?? items.endIndex)
    }

    private mutating func updateTurn(_ turnId: String, _ change: (inout TranscriptTurn) -> Void) {
        if let index = turnIndex(turnId), case var .turn(turn) = items[index] {
            change(&turn)
            items[index] = .turn(turn)
        } else {
            var turn = TranscriptTurn(skeleton: turnId)
            change(&turn)
            insert(turn: turn)
        }
    }

    private mutating func applyAppend(target: TranscriptAppendTarget, offset: Int, chunk: String) -> Bool {
        switch target {
        case let .task(taskId):
            let local = tasks[taskId]?.outputTail ?? ""
            guard let merged = Self.append(local, offset: offset, chunk: chunk) else { return false }
            var task = tasks[taskId] ?? TranscriptTask(taskId: taskId, kind: "other", state: "running")
            task.outputTail = merged
            tasks[taskId] = task
            return true
        case let .frame(turnId, stepId, frameId):
            guard let index = turnIndex(turnId), case var .turn(turn) = items[index],
                  let s = turn.steps.firstIndex(where: { $0.stepId == stepId }),
                  let f = turn.steps[s].frames.firstIndex(where: { $0.frameId == frameId })
            else { return false }
            var frame = turn.steps[s].frames[f]
            guard frame.kind == "text" || frame.kind == "thinking" else { return false }
            guard let merged = Self.append(frame.text ?? "", offset: offset, chunk: chunk) else { return false }
            frame.text = merged
            turn.steps[s].frames[f] = frame
            items[index] = .turn(turn)
            return true
        }
    }

    /// `appendAtOffset`：offset 超出本地长度 = 断档；与已有内容重叠部分必须一致。
    /// offset 按 JS 字符串（UTF-16）计。
    static func append(_ local: String, offset: Int, chunk: String) -> String? {
        let localUnits = Array(local.utf16)
        let chunkUnits = Array(chunk.utf16)
        guard offset <= localUnits.count else { return nil }
        let overlap = localUnits.count - offset
        if overlap >= chunkUnits.count {
            return Array(localUnits[offset ..< offset + chunkUnits.count]) == chunkUnits ? local : nil
        }
        guard Array(localUnits[offset...]) == Array(chunkUnits[..<overlap]) else { return nil }
        return String(decoding: localUnits[..<offset] + chunkUnits, as: UTF16.self)
    }

    private mutating func mergeMeta(_ patch: JSONValue) {
        guard let patch = patch.objectValue else { return }
        for (key, value) in patch {
            switch key {
            case "agent":
                var agent = meta["agent"]?.objectValue ?? [:]
                for (k, v) in value.objectValue ?? [:] { agent[k] = v }
                meta["agent"] = .object(agent)
            default:
                meta[key] = value.isNull ? nil : value
            }
        }
    }

    // MARK: 派生状态

    /// `meta.activity == "turn"`：本轮还在跑。
    var isTurnActive: Bool { meta["activity"]?.stringValue == "turn" }

    var phase: JSONValue? { meta["agent"]?["phase"] }
}
