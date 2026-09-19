import SwiftUI

/// 首屏逐字引导，完成终端准备后进入登录。
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLogin = false
    @State private var revealedCharacters = 0
    @State private var hasFinishedIntro = false

    private let welcome = "欢迎来到Kimi Code Mobile！"
    private let instruction = "使用前，请在你的终端上运行"
    private let command = "kimi rc"

    private var auth: AuthStore { model.auth }
    private var isWorking: Bool { auth.isPreparing || auth.isSigningIn }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 32)

                VStack(spacing: 28) {
                    KimiFace(animating: true)
                        .scaleEffect(4.5)
                        .frame(width: 120, height: 104)
                        .accessibilityHidden(true)

                    if isLogin {
                        VStack(spacing: 14) {
                            (Text("Kimi Code ") + Text("Mobile").foregroundStyle(Palette.kimi))
                                .font(.system(size: 30, weight: .black))
                        }
                    } else {
                        VStack(spacing: 20) {
                            Text(streamed(welcome, offset: 0, brand: true))
                                .font(.system(size: 23, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(streamed(instruction, offset: welcome.count))
                                .font(.system(size: 23, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(streamed(command, offset: welcome.count + instruction.count))
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(welcome)\n\(instruction)\n\(command)")
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 40)

                VStack(spacing: 18) {
                    if let error = auth.lastError, isLogin {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        if isLogin {
                            Task { await auth.signIn() }
                        } else {
                            auth.prepareSignIn()
                            withAnimation(.smooth(duration: 0.3)) { isLogin = true }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isLogin && isWorking {
                                ProgressView().tint(.white)
                                Text(auth.isSigningIn ? "正在登录…" : "正在准备…")
                            } else {
                                Text(isLogin ? "登录 Kimi 账号" : "我已完成")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Palette.kimi, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLogin && isWorking)

                }
                .opacity(hasFinishedIntro ? 1 : 0)
                .allowsHitTesting(hasFinishedIntro)
                .accessibilityHidden(!hasFinishedIntro)
                .frame(maxWidth: 420)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            ZStack {
                Color(.systemBackground)
                LinearGradient(
                    colors: [Palette.kimi.opacity(0.06), .clear, .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
        .animation(.default, value: auth.lastError)
        .task {
            guard !hasFinishedIntro else { return }
            let total = welcome.count + instruction.count + command.count
            if reduceMotion {
                revealedCharacters = total
                hasFinishedIntro = true
                return
            }
            while revealedCharacters < total {
                do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
                revealedCharacters += 1
            }
            withAnimation(.easeIn(duration: 0.3)) { hasFinishedIntro = true }
        }
    }

    /// 保留未显示字符的排版空间，逐字出现时不会挤动 bot 和按钮。
    private func streamed(_ text: String, offset: Int, brand: Bool = false) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .primary
        if brand, let range = result.range(of: "Mobile") {
            result[range].foregroundColor = Palette.kimi
        }
        let visible = min(max(revealedCharacters - offset, 0), text.count)
        let start = result.characters.index(result.startIndex, offsetBy: visible)
        result[start..<result.endIndex].foregroundColor = .clear
        return result
    }

}
