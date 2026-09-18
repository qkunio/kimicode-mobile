import SwiftUI

/// 权限确认卡片。
///
/// 这是手机端最要紧的交互：任务卡在这儿等人点头。所以放在输入框上方、
/// 不用额外点开，命令原文直接可见（要批准的是它，不能藏起来）。
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let resolve: (ApprovalDecisionBody) -> Void

    @State private var isShowingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: approval.symbolName)
                    .foregroundStyle(.orange)
                Text(approval.toolName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let expires = approval.expiresAt?.date {
                    Text(expires, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let description = approval.descriptionText, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let command = approval.command {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    .lineLimit(6)
            } else if let path = approval.filePath {
                Label(path, systemImage: "doc")
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(approval.action)
                    .font(.caption)
                    .lineLimit(3)
            }

            if let cwd = approval.cwd {
                Label(cwd, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            HStack(spacing: 10) {
                Button {
                    resolve(.rejected())
                } label: {
                    Label("拒绝", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(.red)

                Button {
                    resolve(.approved())
                } label: {
                    Label("批准", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }

            Menu {
                Button {
                    resolve(.approved(forSession: true))
                } label: {
                    Label("本会话内都批准", systemImage: "checkmark.circle.badge.checkmark")
                }
                Button {
                    isShowingDetail = true
                } label: {
                    Label("查看完整入参", systemImage: "curlybraces")
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
                    .font(.caption)
            }
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 18))
        .sheet(isPresented: $isShowingDetail) {
            NavigationStack {
                ScrollView {
                    Text(approval.toolInputDisplay?.prettyDescription ?? "（没有入参）")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(approval.toolName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { isShowingDetail = false }
                    }
                }
            }
        }
    }
}
