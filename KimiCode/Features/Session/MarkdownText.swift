import SwiftUI
import UIKit

/// 助手正文的 Markdown 渲染。
///
/// 块级（段落 / 标题 / 列表 / 引用 / 代码块 / 表格 / 分隔线）自己切，行内（粗体 / 行内代码 /
/// 链接）交给 `AttributedString(markdown:)`。流式输出时每次全量重排，只要切块是纯函数就不会闪。
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text))
                .lineSpacing(4)
                .textSelection(.enabled)
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
                .textSelection(.enabled)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Self.inline(item.text))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .quote(text):
            HStack(spacing: 10) {
                Rectangle().fill(Palette.line).frame(width: 3)
                Text(Self.inline(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .table(rows):
            MarkdownTable(rows: rows)
        case .rule:
            Rectangle().fill(Palette.line).frame(height: 0.5).padding(.vertical, 4)
        }
    }

    /// 行内 Markdown。行内代码照官方：0.9 倍等宽、浅底、主题色。
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].foregroundColor = Palette.kimi
            result[run.range].backgroundColor = Palette.fill
        }
        return result
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        let indent: Int
        let text: String
    }

    case paragraph(String)
    case heading(Int, String)
    case list([ListItem], ordered: Bool)
    case quote(String)
    case code(language: String?, code: String)
    case table([[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码块：``` 或 ~~~，未闭合（流式中）就吃到结尾。
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushParagraph()
                blocks.append(.heading(heading.1.count, String(heading.2)))
                index += 1
                continue
            }

            if trimmed.wholeMatch(of: /^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$/) != nil {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // 表格：| a | b | 下一行是 |---|---|
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               lines[index + 1].trimmingCharacters(in: .whitespaces).wholeMatch(of: /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/) != nil {
                flushParagraph()
                var rows: [[String]] = [cells(trimmed)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                var items: [ListItem] = [item.item]
                let ordered = item.ordered
                index += 1
                while index < lines.count {
                    if let next = listItem(lines[index]) {
                        items.append(next.item)
                        index += 1
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[index].hasPrefix("  "), let last = items.popLast() {
                        // 续行：挂到上一项。
                        items.append(ListItem(indent: last.indent, text: last.text + "\n" + lines[index].trimmingCharacters(in: .whitespaces)))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items, ordered: ordered))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func listItem(_ line: String) -> (item: ListItem, ordered: Bool)? {
        let indent = line.prefix { $0 == " " }.count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.firstMatch(of: /^[-*+]\s+(.*)$/) {
            return (ListItem(indent: indent, text: String(match.1)), false)
        }
        if let match = trimmed.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
            return (ListItem(indent: indent, text: String(match.1)), true)
        }
        return nil
    }

    private static func cells(_ row: String) -> [String] {
        var text = row
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// 代码块：顶部语言 + 复制，正文等宽、横向滚动。
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, copied: $copied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Palette.fill, in: .rect(cornerRadius: 8))
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]

    /// 按每列最长的内容估一个列宽（60…240pt），超出的在格子里换行。
    private var widths: [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        return (0 ..< columns).map { column in
            let longest = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                .map { $0.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } }
                .max() ?? 0
            return min(240, max(60, CGFloat(longest) * 8 + 20))
        }
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                            Text(MarkdownText.inline(row.indices.contains(column) ? row[column] : ""))
                                .font(rowIndex == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: width, alignment: .leading)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Rectangle().fill(Palette.line).frame(height: 0.5)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 0.5))
            .padding(0.5)
        }
    }
}

// MARK: - 共用

/// 官方网页端的配色 token（浅色 / 深色两套），对话流里统一从这里取。
enum Palette {
    static let userBubble = dynamic(light: 0xF5F5F5, dark: 0x292929)
    /// `--color-fill-1`：工具面板、代码块底色。
    static let fill = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.03) })
    static let line = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.13) })
    static let danger = dynamic(light: 0xC0392B, dark: 0xF85149)
    static let dangerSoft = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 248 / 255, green: 81 / 255, blue: 73 / 255, alpha: 0.14)
        : UIColor(red: 0xFB / 255, green: 0xEA / 255, blue: 0xEA / 255, alpha: 1) })
    static let diffAdd = dynamic(light: 0x16C456, dark: 0x16C456)
    static let diffDel = dynamic(light: 0xFF4756, dark: 0xFF4756)
    static let kimi = Color("AccentColor")

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 复制按钮：点了变对勾 1.5 秒。
struct CopyButton: View {
    let text: String
    @Binding var copied: Bool

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : "复制")
    }
}
