import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Service restart backoff", .serialized)
struct ServiceRestartBackoffTests {
    @Test("Short-lived runs double the delay and stop at five minutes")
    func exponentialDelayIsCapped() {
        var backoff = ServiceRestartBackoff()
        let delays = (0..<10).map { _ in backoff.nextDelay(initialDelay: 3, runDuration: 0.01) }
        #expect(delays == [3, 6, 12, 24, 48, 96, 192, 300, 300, 300])
    }

    @Test("A stable run resets the next restart to the initial delay")
    func stableRunResetsDelay() {
        var backoff = ServiceRestartBackoff()
        #expect(backoff.nextDelay(initialDelay: 3, runDuration: 0) == 3)
        #expect(backoff.nextDelay(initialDelay: 3, runDuration: 59.99) == 6)
        #expect(backoff.nextDelay(initialDelay: 3, runDuration: 60) == 3)
        #expect(backoff.nextDelay(initialDelay: 3, runDuration: 0) == 6)
    }

    @Test("Configured delays are bounded below and long delays are preserved",
          arguments: [-1, 0, 1, 600, Int.max])
    func configuredDelayBounds(_ configured: Int) {
        var backoff = ServiceRestartBackoff()
        let initial = TimeInterval(max(1, configured))
        #expect(backoff.nextDelay(initialDelay: configured, runDuration: 0) == initial)
        #expect(backoff.nextDelay(initialDelay: configured, runDuration: 0)
                == min(initial * 2, max(initial, 300)))
    }

    @Test("Real automatic restarts back off; manual starts reset only that service",
          arguments: [0, 1])
    @MainActor
    func automaticRestartBacksOff(_ exitCode: Int) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        let task = service(exitCode: exitCode)
        context.insert(task)

        _ = await executor.execute(task: task, modelContext: context)
        let firstRestart = try #require(executor.serviceRestartDates[task.id])
        #expect(abs(firstRestart.timeIntervalSince(task.updatedAt) - 1) < 0.1)
        #expect(!TaskScheduler.shared.runningTaskIDs.contains(task.id))

        try await waitUntil {
            executor.serviceRestartDates[task.id].map { $0 != firstRestart } == true
        }
        let secondRestart = try #require(executor.serviceRestartDates[task.id])
        #expect(abs(secondRestart.timeIntervalSince(task.updatedAt) - 2) < 0.1)

        try await waitUntil {
            executor.serviceRestartDates[task.id].map { $0 != secondRestart } == true
        }
        let thirdRestart = try #require(executor.serviceRestartDates[task.id])
        #expect(abs(thirdRestart.timeIntervalSince(task.updatedAt) - 4) < 0.1)

        let other = service(exitCode: exitCode)
        context.insert(other)
        _ = await executor.execute(task: other, modelContext: context)
        let otherRestart = try #require(executor.serviceRestartDates[other.id])
        #expect(abs(otherRestart.timeIntervalSince(other.updatedAt) - 1) < 0.1)
        executor.cancel(taskId: other.id)
        #expect(executor.serviceRestartDates[task.id] == thirdRestart)

        _ = await executor.execute(task: task, modelContext: context)
        let manualRestart = try #require(executor.serviceRestartDates[task.id])
        #expect(abs(manualRestart.timeIntervalSince(task.updatedAt) - 1) < 0.1)
        executor.cancel(taskId: task.id)
        #expect(executor.serviceRestartDates.isEmpty)
        let updatedAt = task.updatedAt
        try await Task.sleep(for: .milliseconds(1300))
        #expect(task.updatedAt == updatedAt, "Stop during backoff must prevent another execution")
        #expect(executor.runningProcesses.isEmpty)
        #expect(executor.serviceRestartDates.isEmpty)
    }

    @Test("Pending restarts clear when stopped, disabled, deleted, restored or shut down",
          arguments: ["stop", "disable", "delete", "restore", "shutdown", "policy"])
    @MainActor
    func pendingRestartClears(_ action: String) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        let task = service(exitCode: 1)
        context.insert(task)
        _ = await executor.execute(task: task, modelContext: context)
        let taskID = task.id
        let updatedAt = task.updatedAt
        #expect(executor.serviceRestartDates[taskID] != nil)
        switch action {
        case "stop": executor.cancel(taskId: taskID)
        case "disable": task.isEnabled = false
        case "delete": context.delete(task)
        case "restore": await executor.suspendAndDrainForRestore()
        case "shutdown": executor.cancelAll()
        default: task.serviceRestartPolicy = .never
        }
        try context.save()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(executor.serviceRestartDates.isEmpty)
        #expect(executor.runningProcesses.isEmpty)
        if action != "delete" {
            #expect(task.updatedAt == updatedAt)
        }
    }

    @MainActor
    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: ScheduledTask.self, ExecutionLog.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private func service(exitCode: Int) -> ScheduledTask {
        let task = ScheduledTask(name: "backoff service", scriptBody: "exit \(exitCode)", shell: "/bin/sh",
                                 notifyOnSuccess: false, notifyOnFailure: false)
        task.isManualOnly = true
        task.isBackgroundService = true
        task.serviceLogEnabled = false
        task.serviceRestartPolicy = exitCode == 0 ? .always : .onFailure
        task.serviceRestartDelaySeconds = 1
        return task
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for a service restart")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
