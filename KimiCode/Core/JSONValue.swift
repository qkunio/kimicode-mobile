import Foundation

/// 任意 JSON 值。
///
/// 服务端有几处字段是刻意不定型的（`tool_input_display`、`tool_call.input/output`、
/// WS 事件的 `payload`），schema 里就是空对象 `{}`。这些地方硬套具体类型会在遇到
/// 没见过的工具时整条解码失败，所以保留原样，按需取字段。
@dynamicMemberLookup
enum JSONValue: Decodable, Encodable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    // MARK: 取值

    subscript(key: String) -> JSONValue? {
        guard case let .object(dictionary) = self else { return nil }
        return dictionary[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case let .array(items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    subscript(dynamicMember member: String) -> JSONValue? { self[member] }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value): String(value)
        default: nil
        }
    }

    var intValue: Int? {
        if case let .number(value) = self { return Int(value) }
        if case let .string(value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    /// 给 UI 用的紧凑单行预览（工具入参那种）。
    var compactDescription: String {
        switch self {
        case .null: "null"
        case let .bool(value): String(value)
        case let .number(value): value == value.rounded() ? String(Int(value)) : String(value)
        case let .string(value): value
        case let .array(items): "[\(items.map(\.compactDescription).joined(separator: ", "))]"
        case let .object(dictionary):
            "{" + dictionary.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.compactDescription)" }
                .joined(separator: ", ") + "}"
        }
    }

    /// 给详情页用的多行 JSON。
    var prettyDescription: String {
        guard
            let data = try? JSONEncoder.pretty.encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return compactDescription }
        return text
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
