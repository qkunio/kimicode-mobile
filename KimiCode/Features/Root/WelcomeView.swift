import SwiftUI

/// 启动页。
///
/// 两段式：先只有「KIMI CODE」+「开始使用」；点开始使用后按钮滑到底部变成「登录」，
/// 同时后台预取授权，等用户点登录时浏览器能立刻打开。验证码之类的细节不出现在界面上。
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hasStarted = false
    @Namespace private var namespace

    private var auth: AuthStore { model.auth }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("KIMI CODE")
                .font(.system(size: 48, weight: .black))
                .tracking(1.5)

            if hasStarted {
                Text("支持 GO 及以上订阅")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                startButton
                    .padding(.top, 32)
            }

            Spacer()

            if hasStarted {
                VStack(spacing: 12) {
                    if let error = auth.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    loginButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: auth.lastError)
    }

    private var startButton: some View {
        Button {
            auth.prepareSignIn()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                hasStarted = true
            }
        } label: {
            Text("开始使用")
                .font(.headline)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .matchedGeometryEffect(id: "primaryAction", in: namespace)
    }

    private var loginButton: some View {
        Button {
            Task { await auth.signIn() }
        } label: {
            ZStack {
                Text("登录").opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .disabled(isWorking)
        .matchedGeometryEffect(id: "primaryAction", in: namespace)
    }

    private var isWorking: Bool {
        auth.isPreparing || auth.isSigningIn
    }
}
