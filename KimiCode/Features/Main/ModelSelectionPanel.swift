import SwiftUI

/// 选择暂存在面板内，只有点完成才写入会话；下滑关闭即放弃修改。
struct ModelSelectionPanel: View {
    let models: [ModelInfo]
    let confirm: (ModelInfo, String?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?
    @State private var selectedEffort: String?

    init(models: [ModelInfo], config: ComposerConfig, confirm: @escaping (ModelInfo, String?) -> Void) {
        self.models = models
        self.confirm = confirm
        _selectedID = State(initialValue: config.modelID)
        _selectedEffort = State(initialValue: config.effort)
    }

    private var selectedModel: ModelInfo? {
        models.first { $0.model == selectedID }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("配置")
                .font(.headline)
                .padding(.top, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if models.isEmpty {
                        Text("暂无可用模型")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(models) { model in
                                if model.id != models.first?.id {
                                    Divider().padding(.horizontal, 20)
                                }
                                choiceRow(model.name, selected: selectedID == model.model) {
                                    selectedID = model.model
                                    if !model.efforts.contains(selectedEffort ?? "") {
                                        selectedEffort = model.defaultEffort
                                    }
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24))
                    }

                }
                .padding(.horizontal, 24)
            }

            if let model = selectedModel, !model.efforts.isEmpty {
                effortMenu(for: model)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                guard let model = selectedModel else { return }
                confirm(model, effectiveEffort(for: model))
            } label: {
                Text("完成")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(colorScheme == .dark ? Color.white : Color.black, in: .capsule)
            }
            .buttonStyle(.plain)
            .opacity(selectedModel == nil ? 0.4 : 1)
            .disabled(selectedModel == nil)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    private func effectiveEffort(for model: ModelInfo) -> String? {
        if let selectedEffort, model.efforts.contains(selectedEffort) { return selectedEffort }
        if let fallback = model.defaultEffort, model.efforts.contains(fallback) { return fallback }
        return model.efforts.first
    }

    /// 固定在模型列表下方，点击整行弹出原生单选菜单。
    private func effortMenu(for model: ModelInfo) -> some View {
        Menu {
            Picker("思考强度", selection: Binding(
                get: { effectiveEffort(for: model) ?? "" },
                set: { selectedEffort = $0 }
            )) {
                ForEach(model.efforts, id: \.self) { effort in
                    Text(effort.effortLabel).tag(effort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 12) {
                Text("思考强度")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(effectiveEffort(for: model)?.effortLabel ?? "")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("思考强度")
        .accessibilityValue(effectiveEffort(for: model)?.effortLabel ?? "")
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
