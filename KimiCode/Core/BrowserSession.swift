import AuthenticationServices
import UIKit

/// 用系统的 `ASWebAuthenticationSession` 打开 Kimi 的授权确认页。
///
/// device-code 流程里确认页不会回跳 App（没有 redirect），所以这里的 callback scheme
/// 永远不会被触发 —— 登录成功是靠后台轮询发现的，发现后由 `close()` 主动把浏览器收起来。
/// 选它而不是 `openURL` 跳 Safari，就是为了这个"确认完自动回来"。
/// `prefersEphemeralWebBrowserSession = false`：共享 Safari 的 cookie，
/// 用户在 Safari 里登过 kimi.com 的话点一下确认就行。
@MainActor
final class BrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var onDismiss: (() -> Void)?

    var isOpen: Bool { session != nil }

    /// `onDismiss` 只在用户自己关掉浏览器时调用；`close()` 收起的不算。
    func open(_ url: URL, onDismiss: @escaping () -> Void) {
        close()
        self.onDismiss = onDismiss
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme("kimicode")
        ) { [weak self] _, _ in
            Task { @MainActor in self?.userDidDismiss() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    /// 登录成功后由代码收起浏览器。
    func close() {
        onDismiss = nil
        session?.cancel()
        session = nil
    }

    private func userDidDismiss() {
        let callback = onDismiss
        onDismiss = nil
        session = nil
        callback?()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            if let any = scenes.first?.windows.first { return any }
            return ASPresentationAnchor(windowScene: scenes.first!)
        }
    }
}
