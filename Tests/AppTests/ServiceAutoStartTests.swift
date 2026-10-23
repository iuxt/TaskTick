import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Background Service Auto-Start Tests")
@MainActor
struct ServiceAutoStartTests {
    @Test("Auto-start persists without running the process or disabling supervision",
          arguments: [true, false])
    func persistsAutoStart(_ enabled: Bool) throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = ScheduledTask(name: "service", scriptBody: "echo should-not-run")
        task.isBackgroundService = true
        task.isManualOnly = true
        task.isEnabled = false
        task.serviceAutoStart = !enabled
        context.insert(task)
        try context.save()
        var loginRequests = 0

        #expect(setServiceAutoStart(enabled, task: task, context: context) {
            loginRequests += 1
            return true
        })

        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<ScheduledTask>()).first)
        #expect(stored.serviceAutoStart == enabled)
        #expect(stored.isEnabled, "Manual runs must retain restart supervision")
        #expect(stored.nextRunAt == nil)
        #expect(stored.executionLogs.isEmpty, "Changing auto-start must not execute the service")
        #expect(loginRequests == (enabled ? 1 : 0), "Turning off one service must not change TaskTick’s login item")
    }

    @Test("Failed login-item registration preserves the service settings")
    func registrationFailurePreservesState() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = ScheduledTask(name: "legacy disabled service")
        task.isBackgroundService = true
        task.isEnabled = false
        task.serviceAutoStart = false
        context.insert(task)
        try context.save()
        let updatedAt = task.updatedAt

        #expect(!setServiceAutoStart(true, task: task, context: context, enableLaunchAtLogin: { false }))
        #expect(!task.isEnabled)
        #expect(!task.serviceAutoStart)
        #expect(task.updatedAt == updatedAt)
        #expect(!context.hasChanges)
    }

    @Test("Turning off auto-start keeps a running service and its restart policy")
    func runningServiceContinues() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = ScheduledTask(
            name: "running service", scriptBody: "sleep 1", shell: "/bin/sh",
            notifyOnSuccess: false, notifyOnFailure: false
        )
        task.isBackgroundService = true
        task.isManualOnly = true
        task.serviceRestartPolicy = .always
        task.serviceRestartDelaySeconds = 1
        context.insert(task)
        try context.save()
        let executor = ScriptExecutor()
        let run = Task { @MainActor in
            _ = await executor.execute(task: task, modelContext: context)
        }
        do {
            try await waitUntil { executor.runningProcesses[task.id] != nil }
            let process = try #require(executor.runningProcesses[task.id])

            #expect(setServiceAutoStart(false, task: task, context: context))
            #expect(process.isRunning, "Disabling auto-start must not stop the current run")
            try await waitUntil { task.executionLogs.count >= 2 }
            #expect(!task.serviceAutoStart)
            #expect(task.isEnabled)
        } catch {
            await executor.suspendAndDrainForRestore()
            await run.value
            throw error
        }
        await executor.suspendAndDrainForRestore()
        await run.value
    }

    @Test("Scheduled tasks cannot change the login item through service auto-start")
    func scheduledTasksAreUnaffected() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = ScheduledTask(name: "scheduled")
        context.insert(task)
        try context.save()
        var requestedLoginItem = false

        #expect(!setServiceAutoStart(true, task: task, context: context) {
            requestedLoginItem = true
            return true
        })
        #expect(!requestedLoginItem)
        #expect(!context.hasChanges)
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ScheduledTask.self, ExecutionLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for service execution")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
