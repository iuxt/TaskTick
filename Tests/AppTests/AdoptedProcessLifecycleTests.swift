import Foundation
import SwiftData
import Testing
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("Adopted process lifecycle", .serialized)
struct AdoptedProcessLifecycleTests {
    @Test("Startup adopts a surviving scheduled run before dispatching overdue work")
    @MainActor
    func startupAdoptsBeforeScheduling() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        let scheduler = TaskScheduler(executor: executor)
        let task = ScheduledTask(name: "surviving scheduled run", scriptBody: "echo scheduled",
            shell: "/bin/sh", scheduledDate: Date().addingTimeInterval(-3600), repeatType: .hourly,
            notifyOnSuccess: false, notifyOnFailure: false)
        task.nextRunAt = Date().addingTimeInterval(-1)
        context.insert(task)
        let process = try sleepingProcess()
        defer { executor.cancelAll(); scheduler.stop(); stop(process) }
        let log = try runningLog(for: task, process: process, in: context)
        let due = task.nextRunAt

        scheduler.configure(modelContext: context)
        scheduler.start()
        try await Task.sleep(for: .milliseconds(200))

        #expect(scheduler.runningTaskIDs.contains(task.id))
        #expect(executor.adoptedProcesses[task.id]?.pid == process.processIdentifier)
        #expect(executor.runningProcesses.isEmpty)
        #expect(task.executionLogs.count == 1)
        #expect(task.executionCount == 0)
        #expect(task.nextRunAt == due)
        #expect(log.status == .running)

        process.terminate()
        process.waitUntilExit()
        scheduler.pollAdoptedProcesses()
        try await waitUntil {
            task.executionLogs.count == 2 && task.executionLogs.allSatisfy { $0.status != .running }
        }
        #expect(log.status == .cancelled)
        #expect(task.executionLogs.first(where: { $0.id != log.id })?.stdout == "scheduled")
    }

    @Test("Stale fingerprints cannot authorize group cleanup")
    func groupProofRejectsStaleIdentity() throws {
        let process = try sleepingProcess()
        defer { stop(process) }
        let pid = process.processIdentifier
        let stale = ProcessReconciler.Identity(pid: pid, startTime: "different process")
        #expect(stale.captureGroup() == nil)
        #expect(!stale.signalGroup(SIGTERM))
        #expect(process.isRunning)
        let identity = ProcessReconciler.Identity(pid: pid,
            startTime: try #require(ProcessReconciler.startTime(pid: pid)))
        let group = try #require(identity.captureGroup())
        #expect(group.signal(0))
        process.terminate()
        process.waitUntilExit()
        #expect(!group.signal(SIGKILL))
    }

    @Test("Stop and shutdown kill resistant children even after the leader exits",
        arguments: ["stop", "shutdown", "shutdownDuringStop"])
    @MainActor
    func cleanupSurvivesLeaderExit(_ action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasktick-adopted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childFile = root.appendingPathComponent("child.pid")
        let childScript = "trap '' TERM\nprintf '%s' \"$$\" > \(ScriptExecutor.singleQuoted(childFile.path))\nexec /bin/sleep 30"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sh -c \(ScriptExecutor.singleQuoted(childScript)) & wait"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let groupID = process.processIdentifier
        defer { kill(-groupID, SIGKILL); stop(process) }
        try await waitUntil { FileManager.default.fileExists(atPath: childFile.path) }
        let childPID = try #require(Int32(try String(contentsOf: childFile, encoding: .utf8)))

        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        let task = serviceTask()
        task.serviceRestartPolicy = .always
        context.insert(task)
        _ = try runningLog(for: task, process: process, in: context)
        executor.reconcileRunningLogs(in: context)

        if action == "shutdown" {
            executor.cancelAll(graceful: 0.1)
        } else {
            executor.cancel(taskId: task.id)
            try await waitUntil { !process.isRunning }
            #expect(ProcessReconciler.isAlive(pid: childPID))
            // Polling during the grace period must not discard Stop's state.
            #expect(executor.pollAdoptedProcesses(in: context).isEmpty)
            #expect(executor.adoptedProcesses[task.id] != nil)
            if action == "shutdownDuringStop" { executor.cancelAll(graceful: 0.1) }
        }
        try await waitUntil { !ProcessReconciler.isAlive(pid: childPID) }
        try await waitUntil { executor.adoptedProcesses[task.id] == nil }
        if action == "stop" {
            #expect(task.executionLogs.isEmpty)
            #expect(try context.fetchCount(FetchDescriptor<ExecutionLog>()) == 0)
        }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(executor.runningProcesses.isEmpty, "Explicit Stop/shutdown must suppress service restart")
        if action == "stop" { #expect(task.executionLogs.isEmpty) }
    }

    @Test("Adopted service exits follow their restart policy",
        arguments: [ServiceRestartPolicy.always, .onFailure, .never])
    @MainActor
    func adoptedServiceRestartPolicy(_ policy: ServiceRestartPolicy) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        let scheduler = TaskScheduler(executor: executor)
        defer { executor.cancelAll(); scheduler.stop() }
        let task = serviceTask()
        task.serviceRestartPolicy = policy
        context.insert(task)
        let process = try sleepingProcess()
        defer { stop(process) }
        let logID = try runningLog(for: task, process: process, in: context).id
        scheduler.configure(modelContext: context)
        scheduler.start()
        process.terminate()
        process.waitUntilExit()

        scheduler.pollAdoptedProcesses()
        scheduler.pollAdoptedProcesses()
        #expect(executor.adoptedProcesses[task.id] == nil)
        #expect(!scheduler.runningTaskIDs.contains(task.id))
        #expect(task.executionLogs.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ExecutionLog>()) == 0)
        if policy == .never {
            try await Task.sleep(for: .milliseconds(1200))
            #expect(task.executionLogs.isEmpty)
        } else {
            try await waitUntil { executor.runningProcesses[task.id] != nil }
            #expect(task.executionLogs.count == 1)
            #expect(task.executionLogs.first?.id != logID)
            #expect(task.executionLogs.first?.triggeredBy == .launch)
        }
        await executor.suspendAndDrainForRestore()
        #expect(task.executionLogs.isEmpty)
    }

    @Test("Stop, disable and restore suppress a pending adopted-service restart",
        arguments: ["stop", "disable", "restore"])
    @MainActor
    func pendingRestartCanBeSuppressed(_ action: String) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        let task = serviceTask()
        task.serviceRestartPolicy = .always
        context.insert(task)
        let process = try sleepingProcess()
        defer { stop(process) }
        _ = try runningLog(for: task, process: process, in: context)
        executor.reconcileRunningLogs(in: context)
        process.terminate()
        process.waitUntilExit()
        _ = executor.pollAdoptedProcesses(in: context)
        switch action {
        case "stop": executor.cancel(taskId: task.id)
        case "disable": task.isEnabled = false; try context.save()
        default: await executor.suspendAndDrainForRestore()
        }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(task.executionLogs.isEmpty)
        #expect(executor.runningProcesses.isEmpty)
    }

    @MainActor
    private func memoryContainer() throws -> ModelContainer {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        return try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    @MainActor
    private func serviceTask() -> ScheduledTask {
        let task = ScheduledTask(name: "adopted service", scriptBody: "exec /bin/sleep 30", shell: "/bin/sh",
            timeoutSeconds: -1, notifyOnSuccess: false, notifyOnFailure: false)
        task.isManualOnly = true
        task.isBackgroundService = true
        task.serviceLogEnabled = false
        task.serviceRestartDelaySeconds = 1
        return task
    }

    @MainActor
    private func runningLog(for task: ScheduledTask, process: Process, in context: ModelContext) throws -> ExecutionLog {
        let log = ExecutionLog(task: task)
        log.pid = process.processIdentifier
        let startTime = try #require(ProcessReconciler.startTime(pid: process.processIdentifier))
        log.processStartTime = startTime
        context.insert(log)
        try context.save()
        return log
    }

    private func sleepingProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Timed out waiting for process lifecycle transition")
    }
}
