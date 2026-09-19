import SwiftUI

/// 会话右上角的 ⋯：展开看「此对话上下文」和「剩余用量」。
///
///   此对话上下文
///   (◔) 已使用 3.7%
///   ─────────────
///   剩余用量
///   5 小时      53%
///   每月        97%
struct SessionInfoButton: View {
    let chat: ChatModel?

    @Environment(AppModel.self) private var app
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
            Task { await app.refreshUsage() }
        } label: {
            Label("会话信息", systemImage: "ellipsis")
        }
        .popover(isPresented: $isPresented) {
            SessionInfoPanel(chat: chat, usage: app.usage)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SessionInfoPanel: View {
    let chat: ChatModel?
    let usage: PlanUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("此对话上下文")
            contextRow
                .padding(.top, 10)

            Divider()
                .padding(.vertical, 12)

            SectionTitle("剩余用量")
            VStack(alignment: .leading, spacing: 6) {
                if let rows = usage?.rows, !rows.isEmpty {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.title)
                            Spacer(minLength: 24)
                            Text(row.remainingRatio, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                        .font(Self.valueFont)
                        .accessibilityElement(children: .combine)
                    }
                } else if usage == nil {
                    ProgressView()
                } else {
                    Text("暂无用量数据")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
    }

    private var contextRow: some View {
        let ratio = chat?.isDraft == false ? min(max(chat?.contextUsage ?? 0, 0), 1) : 0
        return HStack(spacing: 10) {
            ContextRingGauge(ratio: ratio, lineWidth: 4)
                .frame(width: 26, height: 26)
            Text("已使用 \(ratio.formatted(.percent.precision(.fractionLength(0 ... 1))))")
                .font(Self.valueFont)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// 已使用 / 5 小时 / 每月 / 百分比，与输入框模型名称使用相同字体。
    static let valueFont = Font.subheadline.weight(.medium)
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// 同心圆占比：底圈是整圈轨道，上面一圈按占比描出来。
struct ContextRingGauge: View {
    let ratio: Double
    var lineWidth: CGFloat = 6

    private var tint: Color {
        switch ratio {
        case ..<0.7: Palette.kimi
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            // 0% 时不画：圆头线帽会留下一个点。
            if ratio > 0 {
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .animation(.snappy, value: ratio)
    }
}
