import SwiftUI
import SwiftData
import TaskTickCore

/// Flips a task's enabled flag, recomputes its next fire date and rebuilds the
/// master timer.
///
/// Snapshots all three mutated fields up front so a save failure restores the
/// exact persisted state instead of a recomputed approximation. Shared by the
/// detail view's Enable/Disable button and the task list's context menu — the
/// rollback is subtle enough that two copies would drift.
@MainActor
func toggleTaskEnabled(_ task: ScheduledTask, context: ModelContext) {
    let prevEnabled = task.isEnabled
    let prevNextRunAt = task.nextRunAt
    let prevUpdatedAt = task.updatedAt

    task.isEnabled.toggle()
    task.updatedAt = Date()
    task.nextRunAt = task.isEnabled ? TaskScheduler.shared.computeNextRunDate(for: task) : nil

    do {
        try context.save()
        TaskScheduler.shared.rebuildSchedule()
        if task.isBackgroundService {
            if task.isEnabled && task.serviceAutoStart {
                Task {
                    _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
                }
            } else if !task.isEnabled {
                ScriptExecutor.shared.cancel(taskId: task.id)
            }
        }
    } catch {
        task.isEnabled = prevEnabled
        task.nextRunAt = prevNextRunAt
        task.updatedAt = prevUpdatedAt
        presentErrorAlert(titleKey: "error.save_failed.title",
                          messageKey: "error.save_failed.message",
                          error: error)
    }
}
