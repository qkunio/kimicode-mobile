import Foundation

/// kap-server 把所有 JSON 响应包在统一信封里：`{ code, msg, data, request_id }`。
/// `code == 0` 为成功；其余是业务错误码（见 `KapErrorCode`）。
struct Envelope<Payload: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: Payload?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case code, msg, data
        case requestID = "request_id"
    }
}

/// 错误信封里 `data` 是 null，用它解码失败响应。
struct ErrorEnvelope: Decodable {
    let code: Int
    let msg: String
    let requestID: String?
    let details: [Detail]?

    struct Detail: Decodable {
        let path: String
        let message: String
    }

    enum CodingKeys: String, CodingKey {
        case code, msg, details
        case requestID = "request_id"
    }
}

/// 用得上的业务错误码，来自 `packages/kap-server/src/protocol/error-codes.ts`。
enum KapErrorCode {
    static let ok = 0
    static let validationFailed = 40001
    static let unauthorized = 40101
    static let notFound = 40401
    static let approvalNotFound = 40404
    static let approvalAlreadyResolved = 40902
    static let remoteControlAlreadyRunning = 40903
    static let internalError = 50000
}

enum KapError: LocalizedError {
    /// HTTP 层失败（含 relay 的 401）。
    case http(status: Int, body: String)
    /// 信封里的业务错误码。
    case api(code: Int, message: String)
    case decoding(underlying: any Error, context: String)
    case notConnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            if status == 401 { return "鉴权失败（401）。登录可能已过期，请重新登录。" }
            if status == 404 { return "找不到该设备或接口（404）。设备可能已下线。" }
            if status == 502 { return "隧道无法连到那台电脑（502）。确认它醒着且 `kimi rc` 还在跑。" }
            return "HTTP \(status)\(body.isEmpty ? "" : "：\(body.prefix(200))")"
        case let .api(code, message):
            return "\(message)（code \(code)）"
        case let .decoding(underlying, context):
            return "解析 \(context) 失败：\(underlying)"
        case .notConnected:
            return "尚未连接到任何设备。"
        case .cancelled:
            return "已取消。"
        }
    }

    /// 需要重新走登录流程的错误。
    var requiresReauth: Bool {
        switch self {
        case let .http(status, _): status == 401
        case let .api(code, _): code == KapErrorCode.unauthorized
        default: false
        }
    }
}
