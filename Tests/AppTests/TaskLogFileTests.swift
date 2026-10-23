import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Task log files", .serialized)
@MainActor
struct TaskLogFileTests {
    @Test("Legacy history gets files, and clearing before export never restores old output")
    func legacyHistoryAndClear() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "")
        context.insert(task)
        defer { removeFiles(for: task) }
        let exported = ExecutionLog(task: task)
        exported.status = .success
        exported.stdout = "legacy output"
        context.insert(exported)
        try context.save()

        await TaskLogFiles.backfillHistory(in: container)
        let firstURL = URL(fileURLWithPath: try #require(exported.outputFilePath))
        #expect(try String(contentsOf: firstURL, encoding: .utf8).contains("legacy output"))
        let pending = ExecutionLog(task: task)
        pending.status = .failure
        pending.stderr = "must not reappear"
        context.insert(pending)
        task.executionCount = 7
        try context.save()
        let pendingURL = try #require(LogFileWriter.executionFileURL(
            taskName: task.name, logId: pending.id, startedAt: pending.startedAt))

        try ScriptExecutor().clearLogs(for: task, in: context)
        await TaskLogFiles.backfillHistory(in: container)

        #expect(task.executionLogs.isEmpty)
        #expect(task.executionCount == 7)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: pendingURL.path))
        #expect(try ModelContext(container).fetch(FetchDescriptor<ExecutionLog>()).isEmpty)
    }

    @Test("A stopped background service can clear its retained live buffer and file")
    func clearStoppedService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "echo stopped-output")
        task.isBackgroundService = true
        task.isManualOnly = true
        task.serviceRestartPolicy = .never
        task.serviceLogPath = root.appendingPathComponent("service.log").path
        context.insert(task)
        defer { LiveOutputManager.shared.stopTracking(taskId: task.id) }
        let executor = ScriptExecutor()
        _ = await executor.execute(task: task, modelContext: context)
        #expect(task.executionLogs.isEmpty)
        #expect(LiveOutputManager.shared.stdout(for: task.id) == "stopped-output")

        try executor.clearLogs(for: task, in: context)
        #expect(task.executionLogs.isEmpty)

        #expect(try Data(contentsOf: root.appendingPathComponent("service.log")).isEmpty)
        #expect(LiveOutputManager.shared.stdout(for: task.id) == nil)
        #expect(!LiveOutputManager.shared.isTracking(task.id))
    }

    @Test("Each scheduled execution has a distinct file linked to its recent-run row")
    func scheduledFilesMatchHistory() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "printf 'stdout\\n'; printf 'stderr\\n' >&2")
        context.insert(task)
        defer { removeFiles(for: task) }
        let executor = ScriptExecutor()
        let first = await executor.execute(task: task, triggeredBy: .schedule, modelContext: context)
        let firstURL = URL(fileURLWithPath: try #require(first.outputFilePath))
        let second = await executor.execute(task: task, modelContext: context)
        let secondURL = URL(fileURLWithPath: try #require(second.outputFilePath))

        #expect(firstURL != secondURL)
        #expect(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        #expect(firstURL.deletingLastPathComponent().lastPathComponent == task.name)
        #expect(firstURL.deletingLastPathComponent().deletingLastPathComponent() == LogFileWriter.logsDirectory())
        for url in [firstURL, secondURL] {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("Started:"))
            #expect(text.contains("stdout"))
            #expect(text.contains("stderr"))
        }
        let saved = try ModelContext(container).fetch(FetchDescriptor<ExecutionLog>())
        #expect(Set(saved.compactMap(\.outputFilePath)) == Set([firstURL.path, secondURL.path]))
        let files = try FileManager.default.contentsOfDirectory(at: firstURL.deletingLastPathComponent(),
                                                               includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(task.executionCount == 2)
    }

    @Test("Existing UUID folders and renamed tasks migrate without losing output or empty files")
    func migrateAndRename() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "")
        context.insert(task)
        defer { removeFiles(for: task) }
        let legacyDirectory = try #require(LogFileWriter.legacyExecutionDirectory(for: task.id))
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        for content in ["original output", ""] {
            let log = ExecutionLog(task: task)
            log.status = .success
            log.stdout = "cached output must not replace the file"
            context.insert(log)
            let target = try #require(LogFileWriter.executionFileURL(taskName: task.name, logId: log.id, startedAt: log.startedAt))
            let legacyFile = legacyDirectory.appendingPathComponent(target.lastPathComponent)
            try Data(content.utf8).write(to: legacyFile)
            log.outputFilePath = legacyFile.path
        }
        try context.save()

        await TaskLogFiles.backfillHistory(in: container)
        #expect(!FileManager.default.fileExists(atPath: legacyDirectory.path))
        let oldDirectory = try #require(LogFileWriter.executionDirectory(for: task.name))
        task.name = "改名后的任务-\(task.id)"
        await TaskLogFiles.backfillHistory(in: container)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        var contents: Set<String> = []
        for log in task.executionLogs {
            let file = URL(fileURLWithPath: try #require(log.outputFilePath))
            #expect(file.deletingLastPathComponent().lastPathComponent == task.name)
            contents.insert(try String(contentsOf: file, encoding: .utf8))
        }
        #expect(contents == ["original output", ""])
        let saved = try ModelContext(container).fetch(FetchDescriptor<ExecutionLog>())
        #expect(Set(saved.compactMap(\.outputFilePath)) == Set(task.executionLogs.compactMap(\.outputFilePath)))
    }

    @Test("Tasks sharing a folder keep distinct files and only clear or delete their own output")
    func sameNameOwnership() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "echo first")
        let other = makeTask(script: "echo second")
        other.name = task.name
        context.insert(task)
        context.insert(other)
        defer { removeFiles(for: task); removeFiles(for: other) }
        let executor = ScriptExecutor()
        let first = await executor.execute(task: task, modelContext: context)
        let second = await executor.execute(task: other, modelContext: context)
        let firstURL = URL(fileURLWithPath: try #require(first.outputFilePath))
        let secondURL = URL(fileURLWithPath: try #require(second.outputFilePath))
        #expect(firstURL != secondURL)
        #expect(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        try executor.clearLogs(for: task, in: context)
        #expect(task.executionLogs.isEmpty)
        #expect(other.executionLogs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try String(contentsOf: secondURL, encoding: .utf8).contains("second"))

        let nextRun = await executor.execute(task: task, modelContext: context)
        let nextURL = URL(fileURLWithPath: try #require(nextRun.outputFilePath))
        let paths = task.executionLogs.compactMap(\.outputFilePath)
        let name = task.name
        let id = task.id
        context.delete(task)
        try context.save()
        LogFileWriter.deleteFile(for: name, taskId: id, executionFilePaths: paths)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: nextURL.path))
        #expect(try String(contentsOf: secondURL, encoding: .utf8).contains("second"))
    }

    @Test("A renamed running task moves its file only after the writer closes")
    func renameDuringRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("continue")
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: """
        echo before
        while [ ! -f \(ScriptExecutor.singleQuoted(release.path)) ]; do /bin/sleep 0.05; done
        echo after
        """)
        context.insert(task)
        defer { removeFiles(for: task) }
        let executor = ScriptExecutor()
        let run = Task { @MainActor in
            _ = await executor.execute(task: task, modelContext: context)
        }
        do {
            try await waitUntil { LiveOutputManager.shared.stdout(for: task.id)?.contains("before") == true }
            let log = try #require(task.executionLogs.first)
            let oldPath = try #require(log.outputFilePath)
            task.name = "renamed-\(task.id)"
            try TaskLogFiles.materializeHistoryFile(for: log)
            #expect(log.outputFilePath == oldPath)
            try Data().write(to: release)
            await run.value
            let file = URL(fileURLWithPath: try #require(log.outputFilePath))
            #expect(file.deletingLastPathComponent().lastPathComponent == task.name)
            #expect(!FileManager.default.fileExists(atPath: oldPath))
            let output = try String(contentsOf: file, encoding: .utf8)
            #expect(output.contains("before") && output.contains("after"))
        } catch {
            await executor.suspendAndDrainForRestore()
            await run.value
            throw error
        }
    }

    @Test("Clear deletes completed files and history while preserving counters, scheduling and other tasks")
    func clearDeletesFilesAndHistory() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "echo before")
        let other = makeTask(script: "echo unrelated")
        context.insert(task)
        context.insert(other)
        defer { removeFiles(for: task); removeFiles(for: other) }
        let executor = ScriptExecutor()
        _ = await executor.execute(task: task, modelContext: context)
        _ = await executor.execute(task: task, modelContext: context)
        let unrelated = await executor.execute(task: other, modelContext: context)
        let ids = Set(task.executionLogs.map(\.id))
        let nextScheduledRun = task.nextRunAt
        let files = task.executionLogs.compactMap(\.outputFilePath).map { URL(fileURLWithPath: $0) }
        try executor.clearLogs(for: task, in: context)

        #expect(task.executionLogs.isEmpty)
        #expect(task.executionCount == 2)
        #expect(task.nextRunAt == nextScheduledRun)
        for url in files {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        let saved = try ModelContext(container).fetch(FetchDescriptor<ExecutionLog>())
        #expect(saved.allSatisfy { !ids.contains($0.id) })
        #expect(saved.count == 1)
        #expect(other.executionLogs.count == 1)
        task.name = "renamed-after-clear-\(task.id)"
        await TaskLogFiles.backfillHistory(in: container)
        #expect(task.executionLogs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(LogFileWriter.executionDirectory(for: task.name)).path))
        let otherURL = URL(fileURLWithPath: try #require(unrelated.outputFilePath))
        #expect(try String(contentsOf: otherURL, encoding: .utf8).contains("unrelated"))
        #expect(unrelated.stdout == "unrelated")

        let nextRun = await executor.execute(task: task, modelContext: context)
        let nextURL = URL(fileURLWithPath: try #require(nextRun.outputFilePath))
        #expect(!nextRun.outputFileDeleted)
        #expect(try String(contentsOf: nextURL, encoding: .utf8).contains("before"))
        #expect(task.executionCount == 3)
        #expect(task.executionLogs.count == 1)
        try executor.clearLogs(for: task, in: context)
        try executor.clearLogs(for: task, in: context)
        #expect(!FileManager.default.fileExists(atPath: nextURL.path))
        #expect(task.executionLogs.isEmpty)
    }

    @Test("Clearing history cannot re-arm a task that reached its run-count limit")
    func clearPreservesRunCountLimit() async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "")
        task.repeatType = .everyMinute
        task.scheduledDate = Date().addingTimeInterval(-60)
        task.endRepeatType = .afterCount
        task.endRepeatCount = 3
        task.executionCount = 3
        context.insert(task)
        let log = ExecutionLog(task: task)
        log.status = .success
        log.outputFileDeleted = true
        context.insert(log)
        try context.save()

        try ScriptExecutor().clearLogs(for: task, in: context)
        await TaskLogFiles.backfillHistory(in: container)

        #expect(task.executionLogs.isEmpty)
        #expect(task.executionCount == 3)
        #expect(TaskScheduler.shared.computeNextRunDate(for: task) == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<ExecutionLog>()).isEmpty)
    }

    @Test("Clear during a run removes old output and allows only new output to continue",
          arguments: [false, true])
    func clearRunningOutput(_ isService: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("continue")
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: """
        printf 'before\\n'
        printf 'error-before\\n' >&2
        while [ ! -f \(ScriptExecutor.singleQuoted(release.path)) ]; do /bin/sleep 0.05; done
        printf 'after\\n'
        printf 'error-after\\n' >&2
        """)
        task.isBackgroundService = isService
        task.isManualOnly = isService
        task.timeoutSeconds = -1
        task.serviceRestartPolicy = .never
        task.serviceLogPath = root.appendingPathComponent("service.log").path
        task.serviceLogRotationCount = 1
        context.insert(task)
        defer { removeFiles(for: task); LiveOutputManager.shared.stopTracking(taskId: task.id) }
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        var previousFile: URL?
        if !isService {
            let runningScript = task.scriptBody
            task.scriptBody = "echo previous-run"
            let previous = await executor.execute(task: task, modelContext: context)
            previousFile = URL(fileURLWithPath: try #require(previous.outputFilePath))
            task.scriptBody = runningScript
        }
        let run = Task { @MainActor in
            _ = await executor.execute(task: task, modelContext: context)
        }
        do {
            try await waitUntil { LiveOutputManager.shared.stderr(for: task.id)?.contains("error-before") == true }
            let process = try #require(executor.runningProcesses[task.id])
            let url = try #require(isService
                ? task.serviceLogPath.map { URL(fileURLWithPath: $0) }
                : task.executionLogs.first(where: { $0.status == .running })?.outputFilePath.map { URL(fileURLWithPath: $0) })
            var archives: [URL] = []
            if isService {
                for suffix in [".1", ".7"] {
                    let archive = URL(fileURLWithPath: url.path + suffix)
                    try Data("archived".utf8).write(to: archive)
                    archives.append(archive)
                }
            }
            let unrelated = URL(fileURLWithPath: url.path + ".notes")
            try Data("keep".utf8).write(to: unrelated)
            defer { try? FileManager.default.removeItem(at: unrelated) }

            try executor.clearLogs(for: task, in: context)
            #expect(process.isRunning)
            #expect(LiveOutputManager.shared.isTracking(task.id))
            #expect(LiveOutputManager.shared.stdout(for: task.id) == nil)
            #expect(LiveOutputManager.shared.stderr(for: task.id) == nil)
            #expect(task.executionLogs.contains { $0.status == .running })
            #expect(task.executionLogs.count == 1)
            if let previousFile { #expect(!FileManager.default.fileExists(atPath: previousFile.path)) }
            for file in [url] + archives { #expect(try Data(contentsOf: file).isEmpty) }
            #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
            try Data().write(to: release)
            await run.value

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("before"))
            #expect(text.contains("after"))
            #expect(text.contains("error-after"))
            if isService {
                #expect(task.executionLogs.isEmpty)
                #expect(LiveOutputManager.shared.stdout(for: task.id) == "after")
                #expect(LiveOutputManager.shared.stderr(for: task.id) == "error-after")
            } else {
                #expect(task.executionLogs.count == 1)
                let completed = try #require(task.executionLogs.first)
                #expect(completed.stdout == "after")
                #expect(completed.stderr == "error-after")
                #expect(task.executionCount == 2)
            }
        } catch {
            await executor.suspendAndDrainForRestore()
            await run.value
            throw error
        }
    }

    @Test("Preparation and process-start failures also create a scheduled execution file", arguments: [false, true])
    func failuresHaveFiles(_ preparationFailure: Bool) async throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let task = makeTask(script: "echo never")
        if preparationFailure {
            task.scriptFilePath = "/nonexistent/tasktick-\(UUID().uuidString).sh"
        } else {
            task.shell = "/nonexistent/tasktick-shell"
        }
        context.insert(task)
        defer { removeFiles(for: task) }
        let result = await ScriptExecutor().execute(task: task, modelContext: context)
        let url = URL(fileURLWithPath: try #require(result.outputFilePath))
        #expect(result.status == .failure)
        let error = try #require(result.stderr)
        #expect(!error.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(error))
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: ScheduledTask.self, ExecutionLog.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeTask(script: String) -> ScheduledTask {
        ScheduledTask(name: "日志任务-\(UUID().uuidString)", scriptBody: script, shell: "/bin/sh",
                      notifyOnSuccess: false, notifyOnFailure: false)
    }

    private func removeFiles(for task: ScheduledTask) {
        guard task.modelContext != nil else { return }
        for url in TaskLogFiles.urls(for: task) {
            try? FileManager.default.removeItem(at: url)
            LogFileWriter.removeEmptyDirectory(url.deletingLastPathComponent())
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for process output")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
