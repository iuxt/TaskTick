import Foundation
import SwiftData
import Testing
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("Full review regressions", .serialized)
struct ReviewRegressionTests {
    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test("Cron preserves the repeated DST minute and always advances", arguments: [
        ("* * * * *", "2026-11-01T06:31:00Z"),
        ("*/10 * * * * *", "2026-11-01T06:30:20Z"),
        ("0 * * * * *", "2026-11-01T06:31:00Z")
    ])
    func cronFallBack(_ expression: String, _ expected: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = utc("2026-11-01T06:30:15Z")
        let next = try #require(CronExpression(parsing: expression).nextFireDate(after: now, calendar: calendar))
        #expect(next == utc(expected))
        #expect(next > now)
    }

    @Test("Month-end recurrences stay anchored across clamped months", arguments: [
        (RepeatType.monthly, ["2026-02-28T09:00:00Z", "2026-03-31T09:00:00Z", "2026-04-30T09:00:00Z", "2026-05-31T09:00:00Z", "2026-06-30T09:00:00Z"]),
        (RepeatType.every3Months, ["2026-04-30T09:00:00Z", "2026-07-31T09:00:00Z", "2026-10-31T09:00:00Z"]),
        (RepeatType.every6Months, ["2026-07-31T09:00:00Z", "2027-01-31T09:00:00Z"])
    ])
    @MainActor
    func anchoredMonths(_ repeatType: RepeatType, _ expected: [String]) throws {
        let task = ScheduledTask(scheduledDate: utc("2026-01-31T09:00:00Z"), repeatType: repeatType)
        task.timeZoneIdentifier = "UTC"
        var current = task.scheduledDate!
        for date in expected {
            let next = try #require(TaskScheduler.shared.computeNextRunDate(for: task, after: current))
            #expect(next == utc(date))
            current = next
        }
        // A rebuild after downtime must reach the same anchored occurrence.
        if repeatType == .monthly {
            #expect(TaskScheduler.shared.computeNextRunDate(for: task, after: utc("2026-03-01T00:00:00Z")) == utc("2026-03-31T09:00:00Z"))
        }
    }

    @Test("Yearly and custom monthly recurrences recover their original day")
    @MainActor
    func customAndLeapYearAnchors() {
        let leap = ScheduledTask(scheduledDate: utc("2024-02-29T09:00:00Z"), repeatType: .yearly)
        leap.timeZoneIdentifier = "UTC"
        #expect(TaskScheduler.shared.computeNextRunDate(for: leap, after: utc("2027-03-01T00:00:00Z")) == utc("2028-02-29T09:00:00Z"))
        let monthly = ScheduledTask(scheduledDate: utc("2026-01-31T09:00:00Z"), repeatType: .custom)
        monthly.timeZoneIdentifier = "UTC"
        monthly.customIntervalUnit = .month
        monthly.customIntervalValue = 1
        #expect(TaskScheduler.shared.computeNextRunDate(for: monthly, after: utc("2026-03-01T00:00:00Z")) == utc("2026-03-31T09:00:00Z"))
    }

    @Test("System-zone rebasing preserves civil anchors and backup metadata")
    @MainActor
    func systemZoneAnchorsSurviveRestartAndExport() throws {
        let task = ScheduledTask(scheduledDate: utc("2026-01-01T09:00:00Z"), endRepeatDate: utc("2026-12-31T23:00:00Z"), isEnabled: false)
        task.scheduleAnchorTimeZoneIdentifier = "GMT"
        task.nextRunAt = utc("2026-10-03T09:00:00Z")
        task.additionalTimes = [DateComponents(hour: 18, minute: 30)]
        let exported = TaskExporter.makeExported(task)
        let data = try JSONEncoder().encode(exported)
        let restored = TaskExporter.makeTask(from: try JSONDecoder().decode(TaskExporter.ExportedTask.self, from: data))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(restored.rebaseScheduleIfNeeded(to: tokyo))
        #expect(restored.scheduledDate == utc("2026-01-01T00:00:00Z"))
        #expect(restored.endRepeatDate == utc("2026-12-31T14:00:00Z"))
        #expect(restored.additionalTimes.first?.hour == 18)
        #expect(restored.scheduleAnchorTimeZoneIdentifier == tokyo.identifier)
        #expect(!restored.isEnabled)
        #expect(restored.nextRunAt == nil)
        #expect(!restored.rebaseScheduleIfNeeded(to: tokyo))
        #expect(restored.rebaseScheduleIfNeeded(to: TimeZone(identifier: "GMT")!))
        #expect(restored.scheduledDate == task.scheduledDate)
        #expect(task.rebaseScheduleIfNeeded(to: tokyo))
        #expect(task.nextRunAt == nil)
    }

    @Test("Explicit-zone anchors stay fixed when the system zone changes")
    @MainActor
    func explicitZoneIsFixed() {
        let task = ScheduledTask(scheduledDate: utc("2026-01-01T09:00:00Z"))
        task.timeZoneIdentifier = "UTC"
        #expect(!task.rebaseScheduleIfNeeded(to: TimeZone(identifier: "Asia/Tokyo")!))
        #expect(task.scheduledDate == utc("2026-01-01T09:00:00Z"))
    }

    @Test("Perl validation never executes BEGIN or CHECK blocks")
    func perlIsNonExecuting() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tasktick-perl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let quoted = ScriptExecutor.singleQuoted(marker.path)
        for block in ["BEGIN", "CHECK"] {
            let result = await ScriptValidator.validate(
                scriptBody: "#!/usr/bin/perl\n\(block) { open(my $f, '>', \(quoted)) or die $!; print $f 'executed'; }\n",
                uiShell: "/bin/sh"
            )
            guard case .unsupported("perl") = result else {
                Issue.record("Expected unsupported Perl validation, got \(result)")
                continue
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("A mismatched adopted fingerprint cannot signal the live group")
    func adoptedIdentityRejectsReuse() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let current = ProcessReconciler.Identity(pid: process.processIdentifier,
            startTime: try #require(ProcessReconciler.startTime(pid: process.processIdentifier)))
        #expect(current.isCurrent)
        let stale = ProcessReconciler.Identity(pid: current.pid, startTime: "different process")
        #expect(!stale.isCurrent)
        #expect(!stale.signalGroup(SIGTERM))
        #expect(!stale.signalGroup(SIGKILL))
        #expect(process.isRunning)
        // A matching fingerprint still cannot target a group it does not lead.
        let selfIdentity = ProcessReconciler.Identity(pid: getpid(), startTime: try #require(ProcessReconciler.startTime(pid: getpid())))
        if getpgid(getpid()) != getpid() { #expect(!selfIdentity.signalGroup(0)) }
        process.terminate()
        process.waitUntilExit()
        #expect(!current.isCurrent)
        #expect(!current.signalGroup(SIGKILL))
    }

    @Test("Inline Python uses its shebang, arguments, pre-run, environment and cwd")
    @MainActor
    func inlineInterpreterMatchesValidation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try memoryContainer()
        let task = ScheduledTask(name: "inline-python", scriptBody: "#!/usr/bin/env python3 -u\nimport os, sys\nprint(os.getenv('PRE'), os.getenv('TASK_ENV'), os.path.samefile(os.getcwd(), os.environ['EXPECTED_CWD']), sys.argv[0])\n", shell: "/bin/sh", workingDirectory: root.path, notifyOnSuccess: false, notifyOnFailure: false)
        task.preRunCommand = "export PRE=ready"
        task.environmentVariables = ["TASK_ENV": "present", "EXPECTED_CWD": root.path]
        container.mainContext.insert(task)
        let validation = await ScriptValidator.validate(scriptBody: task.scriptBody, preRun: task.preRunCommand, uiShell: task.shell)
        guard case .success = validation else { Issue.record("Validation failed: \(validation)"); return }
        let log = await ScriptExecutor().execute(task: task, modelContext: container.mainContext)
        #expect(log.status == .success)
        let output = try #require(log.stdout)
        #expect(output.hasPrefix("ready present True "))
        let scriptPath = try #require(output.split(separator: " ").last)
        #expect(!FileManager.default.fileExists(atPath: String(scriptPath)))
    }

    @Test("An unreadable service script finalizes normally and retries in its owning context")
    @MainActor
    func preparationFailureFinalizesAndRestarts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try memoryContainer()
        let context = container.mainContext
        let executor = ScriptExecutor()
        defer { executor.cancelAll() }
        let file = root.appendingPathComponent("service.sh")
        let task = ScheduledTask(name: "missing-service", shell: "/bin/sh", notifyOnSuccess: false, notifyOnFailure: false)
        task.isManualOnly = true
        task.isBackgroundService = true
        task.serviceLogEnabled = false
        task.serviceRestartDelaySeconds = 1
        task.serviceRestartPolicy = .onFailure
        task.scriptFilePath = file.path
        context.insert(task)
        let first = await executor.execute(task: task, modelContext: context)
        #expect(first.status == .failure)
        #expect(first.stderr?.contains(file.path) == true)
        #expect(first.finishedAt != nil)
        #expect(task.lastRunAt != nil)
        #expect(task.executionCount == 1)
        #expect(!LiveOutputManager.shared.isTracking(task.id))
        #expect(!TaskScheduler.shared.runningTaskIDs.contains(task.id))
        try "#!/bin/sh\necho recovered\n".write(to: file, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(5)
        while !task.executionLogs.contains(where: { $0.status == .success }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(task.executionCount == 2)
        #expect(task.executionLogs.contains(where: { $0.stdout == "recovered" && $0.status == .success }))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(task.executionCount == 2)
    }

    @Test("Same-name manual tasks have isolated file logs and matching deletion paths")
    @MainActor
    func manualLogIdentity() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "logs.streamManualToFile")
        defaults.set(true, forKey: "logs.streamManualToFile")
        defer {
            if let previous { defaults.set(previous, forKey: "logs.streamManualToFile") }
            else { defaults.removeObject(forKey: "logs.streamManualToFile") }
        }
        let container = try memoryContainer()
        let name = "review-log-\(UUID().uuidString)"
        let a = ScheduledTask(name: name, scriptBody: "echo first", shell: "/bin/sh", notifyOnSuccess: false, notifyOnFailure: false)
        let b = ScheduledTask(name: name, scriptBody: "echo second", shell: "/bin/sh", notifyOnSuccess: false, notifyOnFailure: false)
        a.isManualOnly = true
        b.isManualOnly = true
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        let aURL = try #require(LogFileWriter.fileURL(for: name, taskId: a.id))
        let bURL = try #require(LogFileWriter.fileURL(for: name, taskId: b.id))
        defer {
            LogFileWriter.deleteFile(for: name, taskId: a.id)
            LogFileWriter.deleteFile(for: name, taskId: b.id)
            LogFileWriter.deleteFile(for: name)
        }
        let executor = ScriptExecutor()
        _ = await executor.execute(task: a, modelContext: container.mainContext)
        _ = await executor.execute(task: b, modelContext: container.mainContext)
        #expect(aURL != bURL)
        #expect(try String(contentsOf: aURL, encoding: .utf8) == "first\n")
        #expect(try String(contentsOf: bURL, encoding: .utf8) == "second\n")
        LogFileWriter.deleteFile(for: name, taskId: a.id)
        #expect(!FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: bURL.path))
    }

    @Test("Directive recognition is independent of read boundaries", arguments: [
        "ordinary prefix @tasktick:notify {\"title\":\"ordinary\"}\n",
        "\u{1b}[32m@tasktick:notify {\"title\":\"real\"}\u{1b}[0m\n",
        "@tasktick:notify {\"title\":\"real\"}",
        "prefix @tasktick:notify {\"title\":\"ordinary\"}"
    ])
    func directiveChunkBoundaries(_ text: String) {
        let bytes = Data(text.utf8)
        let isDirective = text.hasPrefix("@") || text.hasPrefix("\u{1b}")
        for split in 0...bytes.count {
            let scanner = NotificationDirectiveScanner()
            let first = scanner.feed(bytes.prefix(split))
            let second = scanner.feed(bytes.dropFirst(split))
            let tail = scanner.flush()
            let directives = first.directives + second.directives + tail.directives
            let output = first.passthrough + second.passthrough + tail.passthrough
            #expect(directives.count == (isDirective ? 1 : 0), "split=\(split)")
            #expect(output == (isDirective ? Data() : bytes), "split=\(split)")
        }
    }

    @Test("OSC BEL and ST preserve visible output across every chunk boundary", arguments: ["\u{07}", "\u{1b}\\"])
    func outputDecoderBoundaries(_ terminator: String) {
        let text = "\u{1b}]8;;https://example.com\(terminator)可见🙂\u{1b}]8;;\(terminator)\nnext line\n\u{1b}[32mgreen\u{1b}[0m"
        let data = Data(text.utf8)
        let expected = "可见🙂\nnext line\ngreen"
        #expect(decodeProcessOutput(data) == expected)
        #expect(stripANSI(text) == expected)
        for split in 0...data.count {
            var decoder = ProcessOutputDecoder()
            let output = decoder.decode(data.prefix(split)) + decoder.decode(data.dropFirst(split)) + decoder.finish()
            #expect(output == expected, "split=\(split)")
        }
    }

    @Test("Live and file logs share ANSI behavior and isolate stdout/stderr decoder state")
    @MainActor
    func streamingSinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try #require(LogFileWriter(taskName: "test", path: root.appendingPathComponent("output.log").path))
        let live = LiveOutputManager.shared
        let id = UUID()
        live.startTracking(taskId: id)
        defer { live.stopTracking(taskId: id); writer.close() }
        let bytes = Data("\u{1b}]8;;link\u{1b}\\可见🙂\u{1b}]8;;\u{1b}\\\n\u{1b}[32mnext\u{1b}[0m".utf8)
        for byte in bytes {
            let chunk = Data([byte])
            writer.append(chunk)
            live.appendStdout(taskId: id, data: chunk)
            // stderr must remain readable while stdout is in an OSC sequence
            // or waiting for the rest of a Unicode scalar.
            writer.append(Data("X".utf8), stream: .stderr)
            live.appendStderr(taskId: id, data: Data("X".utf8))
        }
        writer.close()
        #expect(live.stdout(for: id) == "可见🙂\nnext")
        #expect(live.stderr(for: id) == String(repeating: "X", count: bytes.count))
        let file = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(file.filter { $0 != "X" } == "可见🙂\nnext")
        #expect(file.filter { $0 == "X" }.count == bytes.count)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasktick-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func memoryContainer() throws -> ModelContainer {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
