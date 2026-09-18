import Foundation

/// 合并密集事件，但不取消正在执行的请求，也不无限推迟首次刷新。
@MainActor
final class RefreshScheduler {
    private var task: Task<Void, Never>?
    private var pendingDelay: Duration?
    private var generation = 0

    func schedule(after delay: Duration, operation: @escaping @MainActor @Sendable () async -> Void) {
        pendingDelay = pendingDelay ?? delay
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.task = nil }
            }
            while let delay = self.pendingDelay {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, self.generation == generation else { return }
                self.pendingDelay = nil
                await operation()
                guard !Task.isCancelled, self.generation == generation else { return }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pendingDelay = nil
    }
}
