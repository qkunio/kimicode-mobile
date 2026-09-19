import SwiftUI

/// 「添加项目」弹窗，照官方网页端 AddWorkspaceDialog：
///   打开时进 `fs:home` 的主目录 → 上一级 / 面包屑 / 点文件夹进入逐级浏览，
///   搜索框在当前目录下模糊搜子文件夹（最多 6 层、浏览 600 个目录、150 条结果），
///   底部「添加「当前目录名」文件夹」把当前目录加成工作区（`POST /workspaces {root}`）。
struct AddWorkspaceSheet: View {
    let client: KapClient
    let add: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var parent: String?
    @State private var entries: [FsBrowse.Entry] = []
    @State private var isBrowsing = true
    @State private var browseFailed = false

    @State private var query = ""
    @State private var matches: [Match] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    @State private var isAdding = false
    @State private var addError: String?

    private struct Match: Identifiable, Hashable {
        let path: String
        let rel: String
        var id: String { path }
    }

    // 官方 Y8t / J8t / tV。
    private static let maxBrowsed = 600
    private static let maxDepth = 6
    private static let maxMatches = 150

    private var folders: [FsBrowse.Entry] { entries.filter(\.isDir) }
    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !browseFailed {
                    pathBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    if !isBrowsing {
                        searchField
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }
                }
                content
                footer
            }
            .navigationTitle("添加文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task { await loadHome() }
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: 顶部：上一级 + 面包屑

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                if let parent { Task { await browse(parent) } }
            } label: {
                Label("返回上级目录", systemImage: "arrow.up")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color(.tertiarySystemFill), in: .capsule)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(parent == nil)
            .opacity(parent == nil ? 0.4 : 1)

            // 默认停在最右侧，并按目录重建：换目录后直接露出最后一段。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, crumb in
                        if index > 1 {
                            Text("/").foregroundStyle(.tertiary)
                        }
                        Button(crumb.label) {
                            Task { await browse(crumb.path) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                    }
                }
                .font(.subheadline)
                .padding(.trailing, 4)
            }
            .defaultScrollAnchor(.trailing)
            .id(path)
        }
    }

    /// 当前目录的最后一级名字（根目录就是 `/`），用在底部按钮上。
    private var folderName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// 官方 `I`：`/` + 各级目录。
    private var crumbs: [(label: String, path: String)] {
        guard !path.isEmpty else { return [] }
        var result: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/\(part)"
            result.append((String(part), current))
        }
        return result
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("在此目录下模糊搜索…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(.tertiarySystemFill), in: .capsule)
    }

    // MARK: 中间：文件夹列表

    @ViewBuilder
    private var content: some View {
        if browseFailed {
            ContentUnavailableView(
                "无法打开此文件夹",
                systemImage: "folder.badge.questionmark",
                description: Text("请检查路径后重试。")
            )
        } else if isBrowsing {
            VStack(spacing: 8) {
                ProgressView()
                Text("加载中…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if isFiltering {
                    ForEach(matches) { match in
                        folderRow(match.rel) { Task { await browse(match.path) } }
                    }
                    if matches.isEmpty {
                        emptyRow(isSearching ? "搜索中…" : "没有匹配「\(query.trimmingCharacters(in: .whitespaces))」的子文件夹")
                    }
                } else {
                    ForEach(folders) { entry in
                        folderRow(entry.name) { Task { await browse(entry.path) } }
                    }
                    if folders.isEmpty {
                        emptyRow("此处没有子文件夹")
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func folderRow(_ title: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .listRowSeparator(.hidden)
    }

    // MARK: 底部：提示 + 添加按钮

    private var footer: some View {
        VStack(spacing: 10) {
            if let addError {
                Text(addError)
                    .font(.footnote)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("点击文件夹进入，再点下方按钮将其添加", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionButton(isAdding ? "添加中…" : "添加「\(folderName)」文件夹", primary: true) {
                Task { await confirm() }
            }
            .disabled(path.isEmpty || isAdding || browseFailed)
            .opacity(path.isEmpty || browseFailed ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: 逻辑

    private func loadHome() async {
        isBrowsing = true
        do {
            let home = try await client.fsHome()
            guard !home.home.isEmpty else {
                browseFailed = true
                isBrowsing = false
                return
            }
            await browse(home.home)
        } catch {
            browseFailed = true
            isBrowsing = false
        }
    }

    /// 官方 `_`：进入某个目录，清空搜索。
    private func browse(_ target: String) async {
        isBrowsing = true
        defer { isBrowsing = false }
        do {
            let result = try await client.browseFs(target)
            guard !result.path.isEmpty else {
                browseFailed = true
                return
            }
            path = result.path
            parent = result.parent
            entries = result.entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            query = ""
            browseFailed = false
            addError = nil
        } catch {
            browseFailed = true
        }
    }

    private func confirm() async {
        guard !path.isEmpty else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            try await add(path)
            dismiss()
        } catch {
            addError = "无法打开此文件夹，请检查路径后重试。"
        }
    }

    /// 输入停 220ms 再搜（官方 debounce）。
    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let term = value.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !path.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        let root = path
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await search(term, under: root)
        }
    }

    /// 官方 `b`：从当前目录广度优先往下找，名字（相对路径）按子序列模糊匹配。
    /// 走隧道每次浏览都是一次往返，所以同一批目录 6 个并发拉。
    private func search(_ term: String, under root: String) async {
        isSearching = true
        defer { if !Task.isCancelled { isSearching = false } }
        var found: [Match] = []
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var browsed = 0
        while !queue.isEmpty, browsed < Self.maxBrowsed, found.count < Self.maxMatches {
            guard !Task.isCancelled else { return }
            let batch = Array(queue.prefix(min(6, Self.maxBrowsed - browsed)))
            queue.removeFirst(batch.count)
            browsed += batch.count
            let listings = await withTaskGroup(of: (Int, FsBrowse?).self) { group in
                for (index, item) in batch.enumerated() {
                    group.addTask { (index, try? await client.browseFs(item.path)) }
                }
                var results = [FsBrowse?](repeating: nil, count: batch.count)
                for await (index, listing) in group { results[index] = listing }
                return results
            }
            guard !Task.isCancelled else { return }
            for (item, listing) in zip(batch, listings) {
                guard let listing else { continue }
                for entry in listing.entries where entry.isDir {
                    let rel = entry.path.hasPrefix(root)
                        ? String(entry.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        : entry.path
                    if found.count < Self.maxMatches, Self.fuzzy(term, rel.isEmpty ? entry.name : rel) {
                        found.append(Match(path: entry.path, rel: rel.isEmpty ? entry.name : rel))
                    }
                    if item.depth + 1 < Self.maxDepth {
                        queue.append((entry.path, item.depth + 1))
                    }
                }
            }
            matches = found
        }
    }

    /// 官方 `y`：term 的字符按顺序出现在 name 里即可（不区分大小写）。
    private static func fuzzy(_ term: String, _ name: String) -> Bool {
        let needle = Array(term.lowercased())
        var index = 0
        for character in name.lowercased() where index < needle.count && character == needle[index] {
            index += 1
        }
        return index == needle.count
    }
}
