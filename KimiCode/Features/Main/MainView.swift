import SwiftUI

/// 主页 + 左侧抽屉。
///
/// 侧栏从左边推进来，主页被推到右边、露出一截（原型图里右侧能看到 composer 的边）。
/// 打开方式：左上角按钮，或在主页往右滑；点露出的主页或往左滑收起。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var isSidebarOpen = false
    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingSidebar = false

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(geometry.size.width * 0.84, 380)
            let progress = openProgress(sidebarWidth: sidebarWidth)

            ZStack(alignment: .leading) {
                NavigationStack {
                    ChatScreen(openSidebar: { setSidebar(open: true, feedback: true) })
                }
                .offset(x: progress * sidebarWidth)
                // NavigationStack 底层是 UIKit，`.offset` 只挪了画面，触摸仍按原位置命中 ——
                // 抽屉开着时它底部的 composer 会抢走侧栏底部那一行的点击。所以开着时整页不接收触摸。
                .allowsHitTesting(!isSidebarOpen)

                // 露出的那截主页：变暗 + 点一下收起。
                // 常驻而不是 `if` 插入：条件插入的视图在过渡中会被画到后面兄弟视图之上，
                // 结果侧栏自己的按钮（退出登录等）点下去全落到这层，侧栏被收起。
                Color.black
                    .opacity(0.18 * progress)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { setSidebar(open: false, feedback: true) }
                    .allowsHitTesting(isSidebarOpen)
                    .zIndex(1)

                SidebarView(close: { setSidebar(open: false) })
                    .frame(width: sidebarWidth)
                    .offset(x: (progress - 1) * sidebarWidth)
                    .zIndex(2)
            }
            .scrollDisabled(isDraggingSidebar)
            .gesture(SidebarPanGesture(
                isOpen: isSidebarOpen,
                onChanged: { translation in
                    isDraggingSidebar = true
                    dragTranslation = translation
                },
                onEnded: { translation, velocity in
                    let projectedOffset = (isSidebarOpen ? sidebarWidth : 0)
                        + translation + velocity * 0.2
                    setSidebar(open: projectedOffset > sidebarWidth / 2, feedback: true)
                },
                onCancelled: { setSidebar(open: isSidebarOpen) }
            ))
        }
        .onChange(of: isSidebarOpen) { _, open in
            if open { Task { await model.refreshSidebar() } }
        }
    }

    private func openProgress(sidebarWidth: CGFloat) -> CGFloat {
        let base: CGFloat = isSidebarOpen ? 1 : 0
        return min(max(base + dragTranslation / sidebarWidth, 0), 1)
    }

    private func setSidebar(open: Bool, feedback: Bool = false) {
        if feedback { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        if open { hideKeyboard() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isSidebarOpen = open
            dragTranslation = 0
            isDraggingSidebar = false
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// 在识别开始前决定方向；一旦横向手势胜出，就独占本次触摸直到抬手。
private struct SidebarPanGesture: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isOpen: isOpen)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // 使用固定的 window 坐标，避免侧栏跟手移动影响位移计算。
        let translation = recognizer.translation(in: recognizer.view?.window).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view?.window).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen: Bool

        init(isOpen: Bool) { self.isOpen = isOpen }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            // 只在开始时判一次方向，后续手指上下偏移不会切回滚动。
            return abs(velocity.x) > abs(velocity.y) * 1.5
                && (isOpen || velocity.x > 0)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 列表滚动先等方向判断；纵向会立即失败放行，横向则取消列表滚动。
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
