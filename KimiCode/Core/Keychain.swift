import Foundation
import OSLog
import Security

/// Keychain 里的一条 generic password。
///
/// 模拟器上未签名/临时签名的 App 偶尔会拿到 `errSecMissingEntitlement (-34018)`，
/// 那种情况下退化成仅本次进程有效的内存存储，并把状态暴露给 UI（不静默降级）。
/// 绝不落 UserDefaults —— refresh token 是能控制用户电脑的凭证。
final class Keychain: @unchecked Sendable {
    static let shared = Keychain()

    private let service = "com.qinkun.kimicode"
    private let logger = Logger(subsystem: "com.qinkun.kimicode", category: "keychain")
    private let lock = NSLock()
    private var memoryFallback: [String: Data] = [:]

    /// Keychain 不可用时为 true，UI 会提示"本次运行后需要重新登录"。
    private(set) var isUsingMemoryFallback = false

    private init() {}

    func set(_ data: Data, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status != errSecSuccess else { return }

        logger.error("keychain 写入失败 (\(status))，本次运行改用内存存储")
        lock.withLock {
            isUsingMemoryFallback = true
            memoryFallback[key] = data
        }
    }

    func data(for key: String) -> Data? {
        if let cached = lock.withLock({ memoryFallback[key] }) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func remove(for key: String) {
        lock.withLock { memoryFallback[key] = nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Codable 便利方法

    func store<Value: Encodable>(_ value: Value, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, for: key)
    }

    func load<Value: Decodable>(_ type: Value.Type, for key: String) -> Value? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
