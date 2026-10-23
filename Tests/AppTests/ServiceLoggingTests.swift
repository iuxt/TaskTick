import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Background service logging")
@MainActor
struct ServiceLoggingTests {
    @Test("Completed services retain live output without execution history", arguments: [0, 1])
    func completedServiceHasNoHistory(_ exitCode: Int) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = service(script: "printf 'output\\n'; printf 'error\\n' >&2; exit \(exitCode)")
        context.insert(task)
        let executor = ScriptExecutor()
        defer {
            executor.cancelAll()
            LiveOutputManager.shared.stopTracking(taskId: task.id)
        }

        let result = await executor.execute(task: task, modelContext: context)
        #expect(result.status == (exitCode == 0 ? .success : .failure))
        #expect(result.stdout == "output")
        #expect(result.stderr == "error")
        #expect(task.executionLogs.isEmpty)
        #expect(task.executionCount == 0)
        #expect(task.lastRunAt == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ExecutionLog>()) == 0)
        #expect(!LiveOutputManager.shared.isTracking(task.id))
        #expect(LiveOutputManager.shared.stdout(for: task.id) == "output")
        #expect(LiveOutputManager.shared.stderr(for: task.id) == "error")

        // A new launch replaces the live buffer rather than building history.
        task.scriptBody = "printf 'new output\\n'"
        _ = await executor.execute(task: task, modelContext: context)
        #expect(LiveOutputManager.shared.stdout(for: task.id) == "new output")
        #expect(LiveOutputManager.shared.stderr(for: task.id) == nil)
        #expect(try context.fetchCount(FetchDescriptor<ExecutionLog>()) == 0)
    }

    @Test("Running services preserve recovery metadata and discard it after Stop")
    func stopDiscardsRunMetadata() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = service(script: "printf 'running\\n'; exec /bin/sleep 30")
        context.insert(task)
        let executor = ScriptExecutor()
        defer {
            executor.cancelAll()
            LiveOutputManager.shared.stopTracking(taskId: task.id)
        }
        let run = Task { @MainActor in
            await executor.execute(task: task, modelContext: context).status
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while LiveOutputManager.shared.stdout(for: task.id) != "running" {
            if ContinuousClock.now >= deadline {
                await executor.suspendAndDrainForRestore()
                _ = await run.value
                Issue.record("Timed out waiting for live service output")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<ExecutionLog>()).first)
        #expect(stored.status == .running)
        #expect(stored.pid != nil)
        #expect(stored.processStartTime != nil)
        #expect(RunningDuration.startedAt(for: task) != nil)
        #expect(LiveOutputManager.shared.isTracking(task.id))

        executor.cancel(taskId: task.id)
        let status = await run.value
        #expect(status == .cancelled)
        #expect(task.executionLogs.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ExecutionLog>()) == 0)
        #expect(LiveOutputManager.shared.stdout(for: task.id) == "running")
    }

    private func service(script: String) -> ScheduledTask {
        let task = ScheduledTask(name: "service", scriptBody: script, shell: "/bin/sh",
                                 timeoutSeconds: -1, notifyOnSuccess: false, notifyOnFailure: false)
        task.isManualOnly = true
        task.isBackgroundService = true
        task.serviceRestartPolicy = .never
        task.serviceLogEnabled = false
        return task
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: ScheduledTask.self, ExecutionLog.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
