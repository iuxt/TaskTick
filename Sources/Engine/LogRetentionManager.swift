import Foundation
import SwiftData
import TaskTickCore

/// Enforces the retention preference automatically. Cleanup runs once during
/// launch and then daily, using a private ModelContext so large deletions never
/// block the main actor. The durable ScheduledTask.executionCount is left alone:
/// pruning diagnostic history must not re-arm an `afterCount` schedule.
@MainActor
final class LogRetentionManager {
    static let shared = LogRetentionManager()

    private var container: ModelContainer?
    private var timer: Timer?

    private init() {}

    func start(container: ModelContainer) {
        self.container = container
        timer?.invalidate()
        runCleanup()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCleanup() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runCleanup() {
        guard let container else { return }
        let configured = UserDefaults.standard.object(forKey: "logRetentionDays") as? Int ?? 30
        let days = max(0, configured)
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        Task {
            let deleted = await Self.deleteExpiredLogs(in: container, before: cutoff)
            if deleted > 0 {
                NSLog("Log retention removed \(deleted) expired execution log(s)")
            }
        }
    }

    /// Internal for deterministic tests. Running rows are retained even if their
    /// start date is old; the executor/reconciler owns their terminal transition.
    nonisolated static func deleteExpiredLogs(
        in container: ModelContainer,
        before cutoff: Date
    ) async -> Int {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let runningRaw = ExecutionStatus.running.rawValue
            let descriptor = FetchDescriptor<ExecutionLog>(
                predicate: #Predicate { $0.startedAt < cutoff && $0.statusRaw != runningRaw }
            )
            guard let logs = try? context.fetch(descriptor), !logs.isEmpty else { return 0 }
            for log in logs { context.delete(log) }
            do {
                try context.save()
                return logs.count
            } catch {
                NSLog("⚠️ Automatic log cleanup failed: \(error.localizedDescription)")
                return 0
            }
        }.value
    }
}
