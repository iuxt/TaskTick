import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("TaskKindFilter Tests")
struct TaskKindFilterTests {
    private func task(isBackgroundService: Bool) -> ScheduledTask {
        let task = ScheduledTask()
        task.isBackgroundService = isBackgroundService
        return task
    }

    @Test("All includes scheduled and background tasks")
    func allIncludesEveryKind() {
        #expect(TaskKindFilter.all.includes(task(isBackgroundService: false)))
        #expect(TaskKindFilter.all.includes(task(isBackgroundService: true)))
    }

    @Test("Scheduled excludes background tasks")
    func scheduledIncludesOnlyNonBackgroundTasks() {
        #expect(TaskKindFilter.scheduled.includes(task(isBackgroundService: false)))
        #expect(!TaskKindFilter.scheduled.includes(task(isBackgroundService: true)))
    }

    @Test("Background excludes scheduled tasks")
    func backgroundIncludesOnlyBackgroundTasks() {
        #expect(TaskKindFilter.background.includes(task(isBackgroundService: true)))
        #expect(!TaskKindFilter.background.includes(task(isBackgroundService: false)))
    }
}
