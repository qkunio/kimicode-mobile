import SwiftUI

/// 主页 + 左侧抽屉。
///
/// 侧栏从左边推进来，主页被推到右边、露出一截（原型图里右侧能看到 composer 的边）。
/// 打开方式：左上角按钮，或从屏幕左边缘往右滑；点露出的主页或往左滑收起。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isSidebarOpen = false
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(geometry.size.width * 0.84, 380)
            let progress = openProgress(sidebarWidth: sidebarWidth)

            ZStack(alignment: .leading) {
                NavigationStack {
                    ChatScreen(openSidebar: { setSidebar(open: true) })
                }
                .offset(x: progress * sidebarWidth)
                // NavigationStack 底层是 UIKit，`.offset` 只挪了画面，触摸仍按原位置命中 ——
                // 抽屉开着时它底部的 composer 会抢走侧栏底部那一行的点击。所以开着时整页不接收触摸。
                .allowsHitTesting(progress < 0.01)

                // 露出的那截主页：变暗 + 点一下收起。
                // 常驻而不是 `if` 插入：条件插入的视图在过渡中会被画到后面兄弟视图之上，
                // 结果侧栏自己的按钮（退出登录等）点下去全落到这层，侧栏被收起。
                Color.black
                    .opacity(0.18 * progress)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { setSidebar(open: false) }
                    .allowsHitTesting(progress > 0.01)
                    .zIndex(1)

                SidebarView(close: { setSidebar(open: false) })
                    .frame(width: sidebarWidth)
                    .offset(x: (progress - 1) * sidebarWidth)
                    .zIndex(2)
            }
            .gesture(dragGesture(sidebarWidth: sidebarWidth))
        }
        .onChange(of: isSidebarOpen) { _, open in
            if open { Task { await model.refreshSidebar() } }
        }
    }

    private func openProgress(sidebarWidth: CGFloat) -> CGFloat {
        let base: CGFloat = isSidebarOpen ? 1 : 0
        return min(max(base + dragTranslation / sidebarWidth, 0), 1)
    }

    private func setSidebar(open: Bool) {
        if open { hideKeyboard() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isSidebarOpen = open
            dragTranslation = 0
        }
    }

    private func dragGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // 关着时只认从左边缘开始的右滑，避免和消息列表的滚动、文本选择打架。
                guard isSidebarOpen || value.startLocation.x < 28 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                guard dragTranslation != 0 else { return }
                let predicted = value.predictedEndTranslation.width
                let shouldOpen = isSidebarOpen
                    ? predicted > -sidebarWidth / 3
                    : predicted > sidebarWidth / 3
                setSidebar(open: shouldOpen)
            }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
