import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Automatic log retention")
struct LogRetentionManagerTests {
    @Test("Expired finished logs are removed without resetting execution count")
    @MainActor
    func removesOnlyExpiredFinishedLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = ScheduledTask(name: "retention")
        task.executionCount = 42
        context.insert(task)
        let unrelated = ScheduledTask(name: "unrelated limited task")
        unrelated.executionCount = 20
        unrelated.endRepeatType = .afterCount
        unrelated.endRepeatCount = 20
        context.insert(unrelated)

        let oldFinished = ExecutionLog(task: task)
        oldFinished.startedAt = Date(timeIntervalSince1970: 100)
        oldFinished.status = .success
        let oldRunning = ExecutionLog(task: task)
        oldRunning.startedAt = Date(timeIntervalSince1970: 100)
        oldRunning.status = .running
        let recentFinished = ExecutionLog(task: task)
        recentFinished.startedAt = Date(timeIntervalSince1970: 300)
        recentFinished.status = .success
        let oldURL = directory.appendingPathComponent("old.log")
        let runningURL = directory.appendingPathComponent("running.log")
        let recentURL = directory.appendingPathComponent("recent.log")
        for (log, url) in [(oldFinished, oldURL), (oldRunning, runningURL), (recentFinished, recentURL)] {
            log.outputFilePath = url.path
            try Data("output".utf8).write(to: url)
        }
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
        let savedTasks = try verification.fetch(FetchDescriptor<ScheduledTask>())
        let savedTask = try #require(savedTasks.first(where: { $0.id == task.id }))
        #expect(savedTask.executionCount == 42)
        let untouched = try #require(savedTasks.first(where: { $0.id == unrelated.id }))
        #expect(untouched.executionCount == 20)
        let nextRun = TaskScheduler.shared.computeNextRunDate(for: untouched)
        #expect(nextRun == nil)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try String(contentsOf: runningURL, encoding: .utf8) == "output")
        #expect(try String(contentsOf: recentURL, encoding: .utf8) == "output")
    }
}
