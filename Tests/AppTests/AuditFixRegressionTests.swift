import Foundation
import SwiftData
import Testing
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("Audit fix regressions", .serialized)
@MainActor
struct AuditFixRegressionTests {
    @Test("Automatic dispatch respects allowances consumed by manual runs", arguments: [false, true])
    func countLimitAtDispatch(_ manuallyConsumed: Bool) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = ScheduledTask(
            name: "audit-count-\(UUID())", scriptBody: "echo allowed", shell: "/bin/sh",
            scheduledDate: Date().addingTimeInterval(-60), repeatType: .everyMinute,
            endRepeatType: .afterCount, endRepeatCount: 1,
            notifyOnSuccess: false, notifyOnFailure: false
        )
        context.insert(task)
        let executor = ScriptExecutor()
        let scheduler = TaskScheduler(executor: executor, isLaunchAtLoginEnabled: { false })
        defer {
            scheduler.stop()
            executor.cancelAll()
            LogFileWriter.deleteFile(for: task.name, taskId: task.id,
                executionFilePaths: task.executionLogs.compactMap(\.outputFilePath))
        }
        if manuallyConsumed { _ = await executor.execute(task: task, modelContext: context) }
        task.nextRunAt = Date().addingTimeInterval(-1)
        try context.save()
        scheduler.configure(modelContext: context)
        scheduler.start()
        // Give an erroneously queued execution an opportunity to start too.
        try await Task.sleep(for: .milliseconds(500))
        await executor.suspendAndDrainForRestore()
        #expect(task.executionCount == 1)
        #expect(task.executionLogs.count == 1)
        #expect(!task.isEnabled)
        #expect(task.nextRunAt == nil)
        #expect(!scheduler.runningTaskIDs.contains(task.id))
    }

    @Test("C shells execute commands and shebang scripts", arguments: ["/bin/csh", "/bin/tcsh"])
    func cShellExecution(_ shell: String) async throws {
        let container = try memoryContainer()
        let task = ScheduledTask(name: "audit-shell-\(UUID())", shell: shell,
                                 notifyOnSuccess: false, notifyOnFailure: false)
        container.mainContext.insert(task)
        defer {
            LogFileWriter.deleteFile(for: task.name, taskId: task.id,
                executionFilePaths: task.executionLogs.compactMap(\.outputFilePath))
        }
        let executor = ScriptExecutor()
        for script in ["echo works", "#!/usr/bin/env sh\necho works\n"] {
            task.scriptBody = script
            let log = await executor.execute(task: task, modelContext: container.mainContext)
            #expect(log.status == .success, "stderr: \(log.stderr ?? "")")
            #expect(log.stdout == "works")
            let validation = await ScriptValidator.validate(scriptBody: script, uiShell: shell)
            guard case .success = validation else { Issue.record("Validation failed: \(validation)"); continue }
        }
    }

    @Test("env shebang preserves assignments, unsets and quoted split strings", arguments: [
        ("AUDIT_VALUE=present /bin/sh", "present"),
        ("-u AUDIT_VALUE /bin/sh", "unset"),
        ("-i /bin/sh", "unset"),
        ("-S AUDIT_VALUE='two words' /bin/sh", "two words"),
        ("-i -S AUDIT_VALUE='two words' /bin/sh", "two words"),
        ("AUDIT_VALUE=${NOT_EXPANDED} /bin/sh", "${NOT_EXPANDED}")
    ])
    func envShebangExecution(_ arguments: String, _ expected: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasktick-env-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("script with 'quote.sh")
        let script = "#!/usr/bin/env \(arguments)\nprintf '%s\\n' \"${AUDIT_VALUE-unset}\"\n"
        try script.write(to: file, atomically: true, encoding: .utf8)
        let container = try memoryContainer()
        let task = ScheduledTask(name: "audit-env-\(UUID())", shell: "/bin/sh",
                                 notifyOnSuccess: false, notifyOnFailure: false)
        task.preRunCommand = "export AUDIT_VALUE=original"
        container.mainContext.insert(task)
        defer {
            LogFileWriter.deleteFile(for: task.name, taskId: task.id,
                executionFilePaths: task.executionLogs.compactMap(\.outputFilePath))
        }
        let executor = ScriptExecutor()
        for inline in [true, false] {
            task.scriptBody = inline ? script : ""
            task.scriptFilePath = inline ? nil : file.path
            let log = await executor.execute(task: task, modelContext: container.mainContext)
            #expect(log.status == .success, "stderr: \(log.stderr ?? "")")
            #expect(log.stdout == expected)
        }
    }

    @Test("Custom schedule previews match the saved cadence", arguments: [
        (CustomRepeatUnit.second, 10, 10.0),
        (CustomRepeatUnit.minute, 5, 300.0),
        (CustomRepeatUnit.hour, 2, 7200.0)
    ])
    func customSchedulePreview(_ unit: CustomRepeatUnit, _ value: Int, _ seconds: Double) {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        var config = TaskScheduleConfiguration()
        config.scheduledDate = anchor
        config.repeatType = .custom
        config.customIntervalValue = value
        config.customIntervalUnit = unit
        config.timeZoneID = "UTC"
        let task = ScheduledTask()
        config.apply(to: task)
        let preview = config.nextRun(after: anchor, taskID: task.id, executionCount: 0)
        #expect(preview == anchor.addingTimeInterval(seconds))
        #expect(preview == TaskScheduler.shared.computeNextRunDate(for: task, after: anchor))
    }

    @Test("Preview honors cron, jitter, exhausted counts and unanchored repeats")
    func completeSchedulePreview() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = ScheduledTask()
        var config = TaskScheduleConfiguration()
        config.useCron = true
        config.cronExpression = "0 9 * * *"
        config.timeZoneID = "Asia/Shanghai"
        config.jitterSeconds = 60
        config.apply(to: task)
        let preview = config.nextRun(after: now, taskID: task.id, executionCount: 0)
        #expect(preview != nil)
        #expect(preview == TaskScheduler.shared.computeNextRunDate(for: task, after: now))
        config.endRepeatType = .afterCount
        config.endRepeatCount = 3
        #expect(config.nextRun(after: now, taskID: task.id, executionCount: 3) == nil)
        config.useCron = false
        config.jitterSeconds = 0
        config.hasDate = false
        config.hasTime = false
        config.repeatType = .everyMinute
        #expect(config.nextRun(after: now, taskID: task.id, executionCount: 0) == now.addingTimeInterval(60))
        config.isManualOnly = true
        #expect(config.nextRun(after: now, taskID: task.id, executionCount: 0) == nil)
    }

    private func memoryContainer() throws -> ModelContainer {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
