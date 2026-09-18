import Foundation
import Observation
import UIKit

/// Kimi 账号凭证。
///
/// relay 认的是 **refresh token**（不是 access token）—— 与桌面端隧道一致，
/// 见 CLAUDE.md §1.6 的实测结果。所以这里主要关心 refreshToken。
struct KimiCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// access token 的到期时间（Unix 秒）。refresh token 自己约 30 天。
    let expiresAt: TimeInterval
    let scope: String?
    let tokenType: String?

    var accessTokenIsExpired: Bool {
        Date().timeIntervalSince1970 >= expiresAt - 60
    }
}

/// device-code 授权。user code 已经编码在 `verificationURIComplete` 里，不展示给用户。
struct DeviceAuthorization: Sendable {
    let userCode: String
    let deviceCode: String
    let verificationURI: String
    let verificationURIComplete: String
    let interval: TimeInterval
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
    /// 预取的授权放久了再用，要留出用户在网页里操作的时间。
    var isExpiringSoon: Bool { Date() >= expiresAt.addingTimeInterval(-120) }
}

/// 账号状态机。
///
/// 流程与 `kimi login` 完全一致（`packages/oauth/src/oauth.ts`），只是验证码不展示给用户：
///   1. 点「开始使用」→ 后台 POST /api/oauth/device_authorization 预取授权（`prepareSignIn`）
///   2. 点「登录」→ 系统浏览器打开 verification_uri_complete（链接自带 user code，无需手输）
///   3. 同时轮询 POST /api/oauth/token；用户在网页里确认后拿到 token，自动收起浏览器
@MainActor
@Observable
final class AuthStore {
    enum State: Sendable {
        case signedOut
        /// 浏览器已打开，等用户确认。
        case signingIn
        case signedIn
    }

    private(set) var state: State = .signedOut
    private(set) var lastError: String?
    /// 正在向 auth 服务要授权（点「登录」时预取还没回来）。
    private(set) var isPreparing = false
    /// Keychain 不可用（模拟器常见），登录只在本次运行内有效。
    var credentialStorageIsEphemeral: Bool { Keychain.shared.isUsingMemoryFallback }

    private static let credentialKey = "kimi-credential"
    private static let deviceIDKey = "kimi-device-id"

    private var credential: KimiCredential?
    private var prepared: DeviceAuthorization?
    private var prepareTask: Task<DeviceAuthorization?, Never>?
    private var pollTask: Task<Void, Never>?
    private let browser = BrowserSession()

    init() {
        if let stored = Keychain.shared.load(KimiCredential.self, for: Self.credentialKey) {
            credential = stored
            state = .signedIn
        }
        #if DEBUG
        // 开发用：`SIMCTL_CHILD_KIMI_DEBUG_REFRESH_TOKEN=… xcrun simctl launch …` 直接以已登录状态启动，
        // 省掉每次在模拟器里走浏览器确认。不写 Keychain；expiresAt 设成无穷大，**绝不刷新** ——
        // 这个 token 通常借自桌面端 `~/.kimi-code/credentials`，刷新会让服务端轮换它，把 CLI 登出。
        if credential == nil,
           let token = ProcessInfo.processInfo.environment["KIMI_DEBUG_REFRESH_TOKEN"],
           !token.isEmpty {
            credential = KimiCredential(
                accessToken: "",
                refreshToken: token,
                expiresAt: .greatestFiniteMagnitude,
                scope: nil,
                tokenType: nil
            )
            state = .signedIn
        }
        #endif
    }

    /// relay 用这个做 Bearer（认 refresh token，不认 access token）。
    var bearerToken: String? { credential?.refreshToken }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var isSigningIn: Bool {
        if case .signingIn = state { return true }
        return false
    }

    /// 本机的 device id，第一次用时生成并持久化。作为 `X-Msh-Device-Id` 发给 auth 服务。
    ///
    /// 注意：refresh token 的 JWT payload 里绑着签发时的 device_id，
    /// 所以**必须**用 App 自己的 id 走一遍 device-code flow，不能复用桌面端的 token。
    private var deviceID: String {
        if let existing = Keychain.shared.load(String.self, for: Self.deviceIDKey) { return existing }
        let generated = UUID().uuidString
        Keychain.shared.store(generated, for: Self.deviceIDKey)
        return generated
    }

    private var deviceHeaders: [String: String] {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return [
            "X-Msh-Platform": "ios",
            "X-Msh-Version": version,
            "X-Msh-Device-Name": device.name,
            "X-Msh-Device-Model": device.model,
            "X-Msh-Os-Version": device.systemVersion,
            "X-Msh-Device-Id": deviceID,
        ]
    }

    // MARK: 登录

    /// 预取授权，不阻塞 UI。重复调用只发一次请求。
    func prepareSignIn() {
        lastError = nil
        if let prepared, !prepared.isExpiringSoon { return }
        guard prepareTask == nil else { return }
        prepareTask = Task { [weak self] in
            guard let self else { return nil }
            defer { self.prepareTask = nil }
            do {
                let authorization = try await requestDeviceAuthorization()
                prepared = authorization
                return authorization
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// 打开浏览器确认页并开始轮询。预取还没回来就等它；过期了就重取。
    func signIn() async {
        lastError = nil
        if prepared?.isExpiringSoon ?? true {
            prepared = nil
            prepareSignIn()
        }
        let authorization: DeviceAuthorization?
        if let prepared {
            authorization = prepared
        } else {
            isPreparing = true
            authorization = await prepareTask?.value
            isPreparing = false
        }
        guard let authorization, let url = URL(string: authorization.verificationURIComplete) else { return }

        state = .signingIn
        startPolling(authorization)
        browser.open(url) { [weak self] in
            self?.browserDismissedByUser(authorization)
        }
    }

    func signOut() {
        pollTask?.cancel()
        browser.close()
        credential = nil
        prepared = nil
        Keychain.shared.remove(for: Self.credentialKey)
        state = .signedOut
    }

    /// 用户没等确认完就自己关了浏览器：可能已经点过确认、只是轮询还没赶上，所以立刻再问一次。
    /// 仍未完成就回到「登录」按钮，授权码留着，下次点登录直接复用。
    private func browserDismissedByUser(_ authorization: DeviceAuthorization) {
        guard !isSignedIn else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            if case let .success(credential)? = try? await pollToken(deviceCode: authorization.deviceCode) {
                complete(with: credential)
            } else if !isSignedIn {
                state = .signedOut
            }
        }
    }

    private func startPolling(_ authorization: DeviceAuthorization) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll(authorization)
        }
    }

    private func complete(with credential: KimiCredential) {
        self.credential = credential
        Keychain.shared.store(credential, for: Self.credentialKey)
        prepared = nil
        browser.close()
        state = .signedIn
    }

    private func fail(_ message: String) {
        lastError = message
        prepared = nil
        browser.close()
        state = .signedOut
    }

    private func poll(_ authorization: DeviceAuthorization) async {
        var interval = max(authorization.interval, 1)
        while !Task.isCancelled, !authorization.isExpired {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            do {
                switch try await pollToken(deviceCode: authorization.deviceCode) {
                case let .success(credential):
                    complete(with: credential)
                    return
                case .pending:
                    continue
                case .slowDown:
                    interval += 2
                case .denied:
                    fail("授权被拒绝。")
                    return
                case .expired:
                    fail("登录超时，请重试。")
                    return
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        if !Task.isCancelled { fail("登录超时，请重试。") }
    }

    // MARK: HTTP

    private func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        let payload = try await postForm(
            path: "/api/oauth/device_authorization",
            fields: ["client_id": KimiConfig.oauthClientID]
        )
        guard
            let userCode = payload["user_code"]?.stringValue,
            let deviceCode = payload["device_code"]?.stringValue,
            let complete = payload["verification_uri_complete"]?.stringValue
        else {
            throw KapError.api(code: -1, message: "授权响应缺少字段")
        }
        return DeviceAuthorization(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: payload["verification_uri"]?.stringValue ?? complete,
            verificationURIComplete: complete,
            interval: Double(payload["interval"]?.intValue ?? 5),
            expiresAt: Date().addingTimeInterval(Double(payload["expires_in"]?.intValue ?? 600))
        )
    }

    private enum PollOutcome {
        case success(KimiCredential)
        case pending
        case slowDown
        case denied
        case expired
    }

    private func pollToken(deviceCode: String) async throws -> PollOutcome {
        let payload = try await postForm(
            path: "/api/oauth/token",
            fields: [
                "client_id": KimiConfig.oauthClientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ],
            allowErrorStatus: true
        )
        if let credential = Self.credential(from: payload) {
            return .success(credential)
        }
        switch payload["error"]?.stringValue {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        case let other:
            let description = payload["error_description"]?.stringValue ?? other ?? "未知错误"
            throw KapError.api(code: -1, message: "轮询失败：\(description)")
        }
    }

    /// access token 过期后换新的。
    ///
    /// 注意服务端可能轮换 refresh token —— 换到新的必须立刻写回 Keychain，
    /// 否则手上那份就作废了（等于把自己登出）。
    @discardableResult
    func refreshIfNeeded() async -> Bool {
        guard let current = credential, current.accessTokenIsExpired else { return credential != nil }
        do {
            let payload = try await postForm(
                path: "/api/oauth/token",
                fields: [
                    "client_id": KimiConfig.oauthClientID,
                    "refresh_token": current.refreshToken,
                    "grant_type": "refresh_token",
                ],
                allowErrorStatus: true
            )
            guard let refreshed = Self.credential(from: payload) else { return true }
            credential = refreshed
            Keychain.shared.store(refreshed, for: Self.credentialKey)
            return true
        } catch {
            // 刷新失败不立刻登出：relay 认的是 refresh token，它本身可能还有效。
            lastError = error.localizedDescription
            return true
        }
    }

    private static func credential(from payload: [String: JSONValue]) -> KimiCredential? {
        guard
            let accessToken = payload["access_token"]?.stringValue,
            let refreshToken = payload["refresh_token"]?.stringValue
        else { return nil }
        let expiresIn = Double(payload["expires_in"]?.intValue ?? 3600)
        return KimiCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().timeIntervalSince1970 + expiresIn,
            scope: payload["scope"]?.stringValue,
            tokenType: payload["token_type"]?.stringValue
        )
    }

    private func postForm(
        path: String,
        fields: [String: String],
        allowErrorStatus: Bool = false
    ) async throws -> [String: JSONValue] {
        var request = URLRequest(url: KimiConfig.oauthHost.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in deviceHeaders { request.setValue(value, forHTTPHeaderField: name) }
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
        if status != 200, !allowErrorStatus {
            let message = payload["error_description"]?.stringValue
                ?? payload["error"]?.stringValue
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw KapError.http(status: status, body: message)
        }
        if status >= 500 {
            throw KapError.http(status: status, body: "认证服务异常")
        }
        return payload
    }
}
