import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        let scheduler = RefreshScheduler()
        var runs = 0
        var cancelled = 0
        var active = 0
        var maximumActive = 0
        let operation: @MainActor @Sendable () async -> Void = {
            runs += 1
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { cancelled += 1 }
        }
        for _ in 0..<30 {
            scheduler.schedule(after: .milliseconds(15), operation: operation)
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(runs > 0, "Continuous events must not starve refresh")
        try await Task.sleep(for: .milliseconds(150))
        precondition(runs >= 2, "Events during a request must trigger a follow-up")
        precondition(cancelled == 0, "New events must not cancel in-flight refresh")
        precondition(maximumActive == 1, "Scheduled requests must be serial")
        let previous = runs
        scheduler.schedule(after: .seconds(1), operation: operation)
        scheduler.cancel()
        scheduler.schedule(after: .milliseconds(10), operation: operation)
        try await Task.sleep(for: .milliseconds(100))
        precondition(runs == previous + 1, "Restart must not inherit cancelled work")
        print("PASS: continuous events, in-flight completion, follow-up, serial execution, cancellation and restart")
    }
}
