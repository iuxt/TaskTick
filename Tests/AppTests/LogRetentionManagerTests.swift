import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Automatic log retention")
struct LogRetentionManagerTests {
    @Test("Expired finished logs are removed without resetting execution count")
    func removesOnlyExpiredFinishedLogs() async throws {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = ScheduledTask(name: "retention")
        task.executionCount = 42
        context.insert(task)

        let oldFinished = ExecutionLog(task: task)
        oldFinished.startedAt = Date(timeIntervalSince1970: 100)
        oldFinished.status = .success
        let oldRunning = ExecutionLog(task: task)
        oldRunning.startedAt = Date(timeIntervalSince1970: 100)
        oldRunning.status = .running
        let recentFinished = ExecutionLog(task: task)
        recentFinished.startedAt = Date(timeIntervalSince1970: 300)
        recentFinished.status = .success
        context.insert(oldFinished)
        context.insert(oldRunning)
        context.insert(recentFinished)
        try context.save()

        let deleted = await LogRetentionManager.deleteExpiredLogs(
            in: container,
            before: Date(timeIntervalSince1970: 200)
        )
        #expect(deleted == 1)

        let verification = ModelContext(container)
        let remaining = try verification.fetch(FetchDescriptor<ExecutionLog>())
        #expect(Set(remaining.map(\.id)) == Set([oldRunning.id, recentFinished.id]))
        let savedTask = try #require(verification.fetch(FetchDescriptor<ScheduledTask>()).first)
        #expect(savedTask.executionCount == 42)
    }
}
