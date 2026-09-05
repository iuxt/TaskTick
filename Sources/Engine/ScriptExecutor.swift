import Foundation
import SwiftData
import TaskTickCore

/// Strip ANSI escape sequences and terminal control codes.
/// Safe for plain text — only removes invisible control characters.
func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(
        of: "\\x1b\\[[0-9;]*[A-Za-z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b[()][A-Za-z0-9]|[\\x00-\\x08\\x0e-\\x1f]",
        with: "",
        options: .regularExpression
    )
}

/// Strip ANSI codes, simulate \r overwrites, and collapse consecutive empty lines.
/// Use for final output (not live streaming).
func cleanTerminalOutput(_ text: String) -> String {
    var cleaned = stripANSI(text)
    // Simulate \r: for lines containing \r, keep only the text after the last \r
    if cleaned.contains("\r") {
        cleaned = cleaned
            .components(separatedBy: "\n")
            .map { line in
                guard line.contains("\r") else { return line }
                let parts = line.components(separatedBy: "\r")
                return parts.last(where: { !$0.isEmpty }) ?? ""
            }
            .joined(separator: "\n")
    }
    // Collapse runs of blank lines into a single blank line
    cleaned = cleaned.replacingOccurrences(
        of: "\\n{3,}",
        with: "\n\n",
        options: .regularExpression
    )
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Decode process output data, stripping ANSI escape sequences at the byte level first
/// to avoid corrupted multi-byte UTF-8 sequences (ANSI codes can split CJK characters).
func decodeProcessOutput(_ data: Data) -> String {
    var cleaned = Data()
    cleaned.reserveCapacity(data.count)
    var i = data.startIndex
    while i < data.endIndex {
        if data[i] == 0x1B { // ESC
            i = data.index(after: i)
            guard i < data.endIndex else { break }
            if data[i] == 0x5B { // [ → CSI: skip until letter
                i = data.index(after: i)
                while i < data.endIndex {
                    let b = data[i]; i = data.index(after: i)
                    if (0x40...0x7E).contains(b) { break }
                }
            } else if data[i] == 0x5D { // ] → OSC: skip until BEL
                i = data.index(after: i)
                while i < data.endIndex && data[i] != 0x07 { i = data.index(after: i) }
                if i < data.endIndex { i = data.index(after: i) }
            } else if data[i] == 0x28 || data[i] == 0x29 { // charset
                i = data.index(after: i)
                if i < data.endIndex { i = data.index(after: i) }
            }
        } else if data[i] < 0x20 && data[i] != 0x09 && data[i] != 0x0A && data[i] != 0x0D {
            i = data.index(after: i) // strip control chars except tab/newline/CR
        } else {
            cleaned.append(data[i]); i = data.index(after: i)
        }
    }
    return String(decoding: cleaned, as: UTF8.self)
}

/// Executes shell scripts using Process (NSTask) with async output capture.
@MainActor
final class ScriptExecutor: ObservableObject {

    @Published var runningProcesses: [UUID: Process] = [:]

    /// Processes that were running when a previous TaskTick session ended
    /// and we re-acquired on launch. Only have a bare PID — no Foundation
    /// `Process`, no live output capture. Cancellation works via direct
    /// signals to the process group.
    @Published var adoptedProcesses: [UUID: Int32] = [:]

    static let shared = ScriptExecutor()
    private let executionSemaphore = DispatchSemaphore(value: 8)
    private var stoppedServiceIDs: Set<UUID> = []
    private var serviceRestartTasks: [UUID: Task<Void, Never>] = [:]

    private var activeLogs: [UUID: ExecutionLog] = [:]
    private var executionContexts: [UUID: ModelContext] = [:]
    private var executionControls: [UUID: ExecutionControl] = [:]
    private var restartRequests: [UUID: UUID] = [:]

    init() {}

    /// Run a task's script and return the execution log entry.
    @discardableResult
    func execute(task: ScheduledTask, triggeredBy: TriggerType = .manual, modelContext: ModelContext) async -> ExecutionLog {
        // All entry points share this guard, including simultaneous UI/CLI runs.
        if let active = activeLogs[task.id] { return active }
        if adoptedProcesses[task.id] != nil,
           let active = task.executionLogs.first(where: { $0.status == .running }) {
            return active
        }
        if task.isBackgroundService {
            stoppedServiceIDs.remove(task.id)
            serviceRestartTasks.removeValue(forKey: task.id)?.cancel()
        }
        // Mark as running so every UI surface (list dot animation, menu bar
        // spinner, detail view stop button) reacts consistently regardless of
        // which entry point triggered the run. Set is idempotent, so callers
        // that also insert (TaskScheduler.fireTask) stay correct.
        TaskScheduler.shared.runningTaskIDs.insert(task.id)
        let executionTaskID = task.id
        let log = ExecutionLog(task: task, triggeredBy: triggeredBy)
        activeLogs[executionTaskID] = log
        executionContexts[log.id] = modelContext
        executionControls[executionTaskID] = ExecutionControl()
        defer {
            activeLogs.removeValue(forKey: executionTaskID)
            executionContexts.removeValue(forKey: log.id)
            executionControls.removeValue(forKey: executionTaskID)
            runningProcesses.removeValue(forKey: executionTaskID)
            TaskScheduler.shared.runningTaskIDs.remove(executionTaskID)
        }
        modelContext.insert(log)
        let startTime = Date()
        // Bump the manual-run recency NOW (not at end) so long-running scripts
        // — dev servers, watchers, anything that runs for hours — surface to
        // the top of the lists immediately when the user hits play, instead
        // of staying buried until the process eventually exits.
        if triggeredBy == .manual {
            task.lastManualRunAt = startTime
        }
        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }

        // Capture task properties before going off main actor
        let shell = task.shell
        let preRunCommand = task.preRunCommand
        let workingDirectory = task.workingDirectory
        let envVars = task.environmentVariables
        let timeoutSeconds = task.timeoutSeconds
        let taskId = task.id
        let ignoreExitCode = task.ignoreExitCode
        let taskName = task.name
        let isBackgroundService = task.isBackgroundService
        let serviceLogEnabled = task.serviceLogEnabled
        let serviceLogPath = task.serviceLogPath
        let serviceLogMaxBytes = Int64(max(1, task.serviceLogMaxSizeMB)) * 1_048_576
        let serviceLogRotationCount = max(0, task.serviceLogRotationCount)
        let notifyOnSuccess = task.notifyOnSuccess
        let notifyOnFailure = task.notifyOnFailure
        let notifyOnlyWhenOutput = task.notifyOnlyWhenOutput
        let strongReminder = task.strongReminder
        // Switch off → empty template → every channel keeps its default wording,
        // while the text the user wrote stays on the task for later.
        let notificationTemplate = task.notificationTemplateEnabled ? task.notificationTemplate : ""
        let logId = log.id

        // Resolve script: inline body or file content.
        let scriptBody: String
        let effectiveShell: String
        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                // Respect the shebang — but a shebang names an interpreter, not a shell,
                // so a .py/.rb/.js file gets exec'd rather than pasted into `<shell> -c`.
                let resolved = ScriptExecutor.resolveFileExecution(
                    fileContent: content,
                    filePath: filePath,
                    uiShell: shell
                )
                effectiveShell = resolved.shell
                scriptBody = resolved.body
            } else {
                // File not readable
                log.status = .failure
                log.stderr = "Cannot read script file: \(filePath)"
                log.finishedAt = Date()
                log.durationMs = 0
                do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
                return log
            }
        } else {
            scriptBody = task.scriptBody
            effectiveShell = shell
        }

        // Prepend pre-run commands (e.g. proxy exports) into the same shell invocation
        // so exported env vars are visible to the script that follows.
        let finalScript: String = {
            let trimmed = preRunCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? scriptBody : trimmed + "\n" + scriptBody
        }()

        LiveOutputManager.shared.startTracking(taskId: taskId)

        // Manual scripts (dev servers, on-demand jobs) optionally tee their
        // output to ~/Library/Logs/TaskTick/<slug>.log so the user can
        // `tail -f` from a terminal or drop the file into Console.app.
        // Scheduled jobs are excluded — short bursty runs would just churn
        // the file and the database log already covers their needs.
        let logFileWriter: LogFileWriter? = {
            guard task.isManualOnly else { return nil }
            if isBackgroundService {
                guard serviceLogEnabled else { return nil }
                return LogFileWriter(
                    taskName: taskName,
                    taskId: taskId,
                    path: serviceLogPath,
                    append: true,
                    maximumBytes: serviceLogMaxBytes,
                    rotationCount: serviceLogRotationCount
                )
            }
            let enabled = UserDefaults.standard.object(forKey: "logs.streamManualToFile") as? Bool ?? true
            guard enabled else { return nil }
            return LogFileWriter(taskName: taskName)
        }()

        let result = await runProcess(
            shell: effectiveShell,
            script: finalScript,
            workingDirectory: workingDirectory,
            environmentVariables: envVars,
            timeoutSeconds: timeoutSeconds,
            taskId: taskId,
            logId: logId,
            ignoreExitCode: ignoreExitCode,
            logFileWriter: logFileWriter,
            captureLimitBytes: ExecutionLog.maxOutputSize
        )

        let endTime = Date()
        let durationMs = Int(endTime.timeIntervalSince(startTime) * 1000)

        // After await, task or log may have been deleted (user deleted task during execution).
        // Re-fetch from context to check they still exist before writing.
        let logDescriptor = FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.id == logId })
        let taskDescriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        let fetchedLog = try? modelContext.fetch(logDescriptor).first
        let fetchedTask = try? modelContext.fetch(taskDescriptor).first

        if let fetchedLog {
            fetchedLog.stdout = ExecutionLog.truncateOutput(result.stdout)
            fetchedLog.stderr = ExecutionLog.truncateOutput(result.stderr)
            fetchedLog.exitCode = result.exitCode
            fetchedLog.status = result.status
            fetchedLog.finishedAt = endTime
            fetchedLog.durationMs = durationMs
        }

        if let fetchedTask {
            fetchedTask.lastRunAt = endTime
            // Note: lastManualRunAt is set at task START (above) so running
            // scripts surface immediately. No need to update it again here.
            fetchedTask.updatedAt = endTime
            // Keep executionCount in sync for both manual and scheduled runs so the UI
            // badge and any downstream checks reflect actual completed executions.
            fetchedTask.executionCount = fetchedTask.executionLogs
                .filter { $0.modelContext != nil }
                .count
        }

        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
        LiveOutputManager.shared.stopTracking(taskId: taskId)

        // Send notification using pre-captured properties (safe even if task was deleted)
        let globalNotificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        let durationText = "\(L10n.tr("notification.duration")) \(ExecutionLog.formatDuration(durationMs))"

        // A task's custom reminder text (issue #48) is rendered once and shared
        // by system notifications and the strong reminder below
        // so the same run reads identically wherever the user sees it. nil
        // means "no template configured": each channel keeps its own wording.
        let customBody = NotificationTemplate.render(
            notificationTemplate,
            context: NotificationTemplate.Context(
                taskName: taskName,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                durationMs: durationMs,
                succeeded: result.status == .success
            )
        )
        let customNotificationBody = customBody.map(NotificationTemplate.clampForNotification)

        if result.status == .failure || result.status == .timeout {
            let exitInfo = "Exit code: \(result.exitCode ?? -1)"
            let stderrLine = result.stderr.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            let body = customNotificationBody
                ?? [exitInfo, durationText, stderrLine].filter { !$0.isEmpty }.joined(separator: " · ")
            let title = "[\(L10n.tr("notification.failed"))] \(taskName)"
            if globalNotificationsEnabled && notifyOnFailure {
                NotificationManager.shared.sendNotification(title: title, body: body)
            }
        } else if result.status == .success {
            // "Notify only when output present" mode: polling scripts stay silent on
            // empty runs and only chirp when they `echo` something meaningful.
            // Whitespace-only stdout counts as no output (a script ending in a stray
            // newline shouldn't fire a notification).
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(notifyOnlyWhenOutput && trimmedStdout.isEmpty) {
                // Prefer stdout, fall back to stderr when stdout has no meaningful content
                let outputSource = ScriptExecutor.hasMeaningfulContent(result.stdout) ? result.stdout : result.stderr
                let outputLine = NotificationTemplate.firstMeaningfulLine(of: outputSource)
                let body = [durationText, outputLine].filter { !$0.isEmpty }.joined(separator: " · ")
                let title = "[\(L10n.tr("notification.succeeded"))] \(taskName)"
                let resolvedBody = customNotificationBody
                    ?? (body.isEmpty ? L10n.tr("notification.success") : body)
                if globalNotificationsEnabled && notifyOnSuccess {
                    NotificationManager.shared.sendNotification(title: title, body: resolvedBody)
                }
            }
        }

        // Strong reminder: show floating panel with the custom reminder text, or
        // the full output when the task has no template.
        // Prefer stdout (actual results); fall back to stderr only if stdout is truly empty
        if result.status == .success && strongReminder {
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // The panel scrolls, so it shows the unclamped text.
            let output = customBody ?? (trimmedStdout.isEmpty ? result.stderr : result.stdout)
            StrongReminderPanel.shared.show(
                taskName: taskName,
                output: output,
                durationMs: durationMs
            )
        }

        if isBackgroundService {
            scheduleServiceRestartIfNeeded(taskId: taskId, lastStatus: result.status)
        }

        return log
    }

    /// Re-launch a managed background command after its configured delay.
    /// A user Stop (or app shutdown) records an explicit suppression marker,
    /// so an in-flight process completion can never resurrect the service.
    private func scheduleServiceRestartIfNeeded(taskId: UUID, lastStatus: ExecutionStatus) {
        guard !stoppedServiceIDs.contains(taskId) else { return }
        let context = TaskTickApp._sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        guard let service = try? context.fetch(descriptor).first,
              service.isEnabled,
              service.isBackgroundService else { return }

        let shouldRestart: Bool = switch service.serviceRestartPolicy {
        case .never: false
        case .onFailure: lastStatus != .success
        case .always: true
        }
        guard shouldRestart else { return }

        let delay = max(1, service.serviceRestartDelaySeconds)
        serviceRestartTasks.removeValue(forKey: taskId)?.cancel()
        serviceRestartTasks[taskId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  !self.stoppedServiceIDs.contains(taskId),
                  !TaskScheduler.shared.runningTaskIDs.contains(taskId) else { return }
            let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
            guard let service = try? context.fetch(descriptor).first,
                  service.isEnabled,
                  service.isBackgroundService else { return }
            self.serviceRestartTasks.removeValue(forKey: taskId)
            _ = await self.execute(task: service, triggeredBy: .launch, modelContext: context)
        }
    }

    /// Wait for the old execution (including pipe draining and log saves) before
    /// starting its replacement. Repeated restart/stop requests supersede this one.
    func restart(taskId: UUID, modelContext: ModelContext) async {
        cancel(taskId: taskId)
        let request = UUID()
        restartRequests[taskId] = request
        defer {
            if restartRequests[taskId] == request { restartRequests.removeValue(forKey: taskId) }
        }
        while activeLogs[taskId] != nil || adoptedProcesses[taskId] != nil {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            guard restartRequests[taskId] == request else { return }
        }
        guard restartRequests[taskId] == request, !Task.isCancelled else { return }
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        guard let task = try? modelContext.fetch(descriptor).first else { return }
        _ = await execute(task: task, modelContext: modelContext)
    }

    /// Cancel a running task. Hits both the immediate child (zsh) and the
    /// whole process group so descendants like `node`, `python`, etc. don't
    /// orphan when zsh exits without forwarding SIGTERM.
    ///
    /// Adopted entries (re-acquired from a previous session) only have a
    /// bare PID — no `Process` object, no waitpid (we're not the parent).
    /// They get SIGTERM with a 3s SIGKILL escalation; we don't waitpid
    /// because launchd has the parent slot.
    func cancel(taskId: UUID) {
        stoppedServiceIDs.insert(taskId)
        serviceRestartTasks.removeValue(forKey: taskId)?.cancel()
        restartRequests.removeValue(forKey: taskId)
        // A queued execution has a control too: Stop prevents it from spawning.
        // The worker owns signals and escalation, even after the leader exits.
        executionControls[taskId]?.requestStop(.cancelled)

        if let adoptedPID = adoptedProcesses[taskId] {
            kill(-adoptedPID, SIGTERM)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard self.adoptedProcesses[taskId] == adoptedPID else { return }
                kill(-adoptedPID, SIGKILL)
                self.finalizeAdoptedLog(taskId: taskId, pid: adoptedPID,
                    reason: "[TaskTick] Adopted process \(adoptedPID) was stopped by user.")
                self.adoptedProcesses.removeValue(forKey: taskId)
                TaskScheduler.shared.runningTaskIDs.remove(taskId)
            }
        }
    }

    /// Walk the most-recent `.running` log for `taskId` to a `.cancelled`
    /// terminal state. Used after we signal an adopted process — we don't
    /// have a `Process.waitUntilExit` to flush the log row for us.
    private func finalizeAdoptedLog(taskId: UUID, pid: Int32, reason: String) {
        let ctx = TaskTickApp._sharedModelContainer.mainContext
        let runningRaw = ExecutionStatus.running.rawValue
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == runningRaw && $0.task?.id == taskId }
        )
        guard let log = try? ctx.fetch(descriptor).first else { return }
        let now = Date()
        log.status = .cancelled
        log.finishedAt = now
        if log.durationMs == nil {
            log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
        }
        if (log.stderr ?? "").isEmpty {
            log.stderr = reason
        }
        try? ctx.save()
    }

    /// Synchronously terminate every running script. Designed for app-quit:
    /// SIGTERM the whole tree, give it `graceful` seconds to clean up, then
    /// SIGKILL anything still alive. Blocks the caller — ok during
    /// applicationWillTerminate, since the app is dying anyway.
    ///
    /// Adopted processes (re-acquired from a previous session, PID-only)
    /// go through the same two-stage flow via process-group signals.
    func cancelAll(graceful: TimeInterval = 0.3) {
        restartRequests.removeAll()
        for control in executionControls.values { control.requestStop(.cancelled) }
        stoppedServiceIDs.formUnion(executionControls.keys)
        stoppedServiceIDs.formUnion(runningProcesses.keys)
        stoppedServiceIDs.formUnion(adoptedProcesses.keys)
        for restartTask in serviceRestartTasks.values { restartTask.cancel() }
        serviceRestartTasks.removeAll()
        let processSnapshot = Array(runningProcesses.values)
        let adoptedSnapshot = Array(adoptedProcesses.values)
        runningProcesses.removeAll()
        adoptedProcesses.removeAll()

        guard !processSnapshot.isEmpty || !adoptedSnapshot.isEmpty else { return }

        for process in processSnapshot where process.isRunning {
            let pid = process.processIdentifier
            kill(-pid, SIGTERM)
            process.terminate()
        }
        for pid in adoptedSnapshot {
            kill(-pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: graceful)

        for process in processSnapshot {
            let pid = process.processIdentifier
            kill(-pid, SIGKILL)
            if process.isRunning { kill(pid, SIGKILL) }
        }
        for pid in adoptedSnapshot where ProcessReconciler.isAlive(pid: pid) {
            kill(-pid, SIGKILL)
        }
    }

    /// Persist the running process's PID + start-time fingerprint to its
    /// ExecutionLog row. The worker captures the fingerprint off the main
    /// actor, then this method writes through the context that owns the run.
    private func persistRunningPID(logId: UUID, pid: Int32, startTime: String?) {
        guard let ctx = executionContexts[logId] else { return }
        let desc = FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.id == logId })
        if let live = try? ctx.fetch(desc).first {
            live.pid = pid
            live.processStartTime = startTime
            try? ctx.save()
        }
    }

    // MARK: - Private

    /// Thread-safe buffer for collecting pipe output from readabilityHandler closures.
    private final class PipeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let _stdout = MutableDataBox()
        private let _stderr = MutableDataBox()
        private let maximumBytes: Int?

        init(maximumBytes: Int? = nil) {
            self.maximumBytes = maximumBytes
        }

        func appendStdout(_ data: Data) {
            lock.lock()
            append(data, to: _stdout)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            append(data, to: _stderr)
            lock.unlock()
        }

        private func append(_ incoming: Data, to box: MutableDataBox) {
            box.data.append(incoming)
            if let maximumBytes, box.data.count > maximumBytes {
                box.data.removeFirst(box.data.count - maximumBytes)
            }
        }

        func read() -> (stdout: Data, stderr: Data) {
            lock.lock()
            let result = (_stdout.data, _stderr.data)
            lock.unlock()
            return result
        }

        private final class MutableDataBox: @unchecked Sendable {
            var data = Data()
        }
    }

    /// Extract the interpreter from a shebang line.
    ///
    /// - `#!/opt/homebrew/bin/bash` → `/opt/homebrew/bin/bash` (must exist on disk)
    /// - `#!/usr/bin/env python3` → `python3` — a *bare name*, deliberately left for the
    ///   wrapping shell to resolve at run time. By then `runProcess` has applied Homebrew's
    ///   shellenv, so it lands on the same binary the user gets in an interactive terminal.
    ///   Resolving it here against the app's own PATH would pick /usr/bin/python3 (3.9)
    ///   instead — the exact mismatch the brewPrefix in `runProcess` exists to avoid.
    ///
    /// Returns nil when there's no shebang, or an absolute interpreter doesn't exist.
    ///
    /// Note: extra interpreter arguments (`#!/usr/bin/env -S python3 -u`) are dropped —
    /// only the interpreter itself is honored.
    nonisolated static func parseShebang(from script: String) -> String? {
        guard let firstLine = script.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!") else { return nil }
        // Strip "#!" and trim whitespace, take the first token
        let interpreterLine = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let parts = interpreterLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first, !first.isEmpty else { return nil }
        // "#!/usr/bin/env <interpreter>" — skip env's own flags (e.g. -S), keep the name.
        if first == "/usr/bin/env" {
            guard let cmd = parts.dropFirst().first(where: { !$0.hasPrefix("-") }),
                  !cmd.isEmpty else { return nil }
            return cmd
        }
        // Direct path like "#!/opt/homebrew/bin/bash"
        if FileManager.default.isExecutableFile(atPath: first) {
            return first
        }
        return nil
    }

    /// Shell prelude that drops a run into the user's interactive environment:
    /// Homebrew's shellenv, then the rc file matching the shell.
    ///
    /// Shared by execution and validation so `python3` / `node` / `jq` resolve to the
    /// same binaries in both. Without the Homebrew part they fall back to the system
    /// copies (e.g. /usr/bin/python3 3.9) rather than what's on the user's interactive
    /// $PATH — the mismatch that once surfaced as "script output gets truncated" when
    /// an inline python3 hit a syntax feature newer than 3.9.
    nonisolated static func environmentPrelude(for shell: String) -> String {
        let fm = FileManager.default
        let brewPrefix: String
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            brewPrefix = "eval \"$(/opt/homebrew/bin/brew shellenv 2>/dev/null)\"; "
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/brew") {
            brewPrefix = "eval \"$(/usr/local/bin/brew shellenv 2>/dev/null)\"; "
        } else {
            brewPrefix = ""
        }
        if shell.hasSuffix("zsh") {
            return brewPrefix + "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; "
        }
        if shell.hasSuffix("bash") {
            return brewPrefix + "[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; "
        }
        return brewPrefix
    }

    /// Whether an interpreter speaks the `-l -c "<script text>"` calling convention
    /// that `runProcess` uses. Only shells do; python/ruby/node reject `-l` outright.
    ///
    /// The list comes from `/etc/shells` at run time rather than a hardcoded set of
    /// names, so a user's non-standard login shell is recognized too. Compared by
    /// basename because a shebang may name the interpreter without a path.
    nonisolated static func isShellInterpreter(_ interpreter: String) -> Bool {
        let name = (interpreter as NSString).lastPathComponent
        return AvailableShells.load().contains { ($0 as NSString).lastPathComponent == name }
    }

    /// Wrap a value in single quotes so spaces/quotes in a path can't split the command.
    nonisolated static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Decide which shell wraps the run, and what text that shell is handed, for a
    /// task backed by a script *file*.
    ///
    /// The distinction that matters: a shebang names an **interpreter**, which is not
    /// necessarily a **shell**. `runProcess` always invokes `<shell> -l -c "<text>"`, so
    /// the file's contents may only be pasted into `<text>` when the interpreter is
    /// itself a shell. For anything else (python/ruby/node/…) we keep the user's shell
    /// as the wrapper — preserving rc files, preRunCommand, env and cwd — and have it
    /// `exec` the real interpreter against the file on disk.
    ///
    /// `exec` matters: it replaces the shell process instead of forking a child, so the
    /// interpreter inherits the same PID. Timeout (SIGTERM→SIGKILL), cancellation and
    /// `ProcessReconciler`'s orphan adoption all act on the process actually doing the
    /// work, not on an idle shell wrapper.
    ///
    /// Pure function so it can be tested without SwiftData — see ScriptExecutorTests.
    nonisolated static func resolveFileExecution(
        fileContent: String,
        filePath: String,
        uiShell: String
    ) -> (shell: String, body: String) {
        guard let interpreter = parseShebang(from: fileContent) else {
            // No usable shebang: fall back to the shell picked in the UI, as before.
            return (uiShell, fileContent)
        }
        // An absolute shell path can run the contents directly — this is the long-standing
        // path for .sh files, kept byte-for-byte identical to avoid any regression.
        if interpreter.hasPrefix("/"), isShellInterpreter(interpreter) {
            return (interpreter, fileContent)
        }
        // Everything else — non-shell interpreters, and bare names like `bash` from
        // `#!/usr/bin/env bash` (which can't be a Process executableURL anyway) — is
        // handed to the interpreter as a file path.
        return (uiShell, "exec \(singleQuoted(interpreter)) \(singleQuoted(filePath))")
    }

    /// Check if a string contains meaningful printable content (not just whitespace).
    /// Pure string math with no actor state, so `NotificationTemplate` can pick
    /// the same output stream off the main actor.
    nonisolated static func hasMeaningfulContent(_ text: String) -> Bool {
        text.contains(where: { !$0.isWhitespace && !$0.isNewline && ($0.asciiValue.map({ $0 >= 32 }) ?? true) })
    }

    private struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int?
        let status: ExecutionStatus
    }

    private func runProcess(
        shell: String,
        script: String,
        workingDirectory: String?,
        environmentVariables: [String: String]?,
        timeoutSeconds: Int,
        taskId: UUID,
        logId: UUID,
        ignoreExitCode: Bool = false,
        logFileWriter: LogFileWriter? = nil,
        captureLimitBytes: Int? = nil
    ) async -> ProcessResult {
        // Use login shell (-l) for .zprofile, then source .zshrc/.bashrc
        // for user environment variables without full interactive mode
        // (which would load oh-my-zsh etc. and slow down execution).
        //
        let rcFile = ScriptExecutor.environmentPrelude(for: shell)

        return await runProcessCore(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", rcFile + script],
            workingDirectory: workingDirectory,
            environmentVariables: environmentVariables,
            timeoutSeconds: timeoutSeconds,
            taskId: taskId,
            logId: logId,
            ignoreExitCode: ignoreExitCode,
            logFileWriter: logFileWriter,
            captureLimitBytes: captureLimitBytes
        )
    }

    /// Lower-level process runner. Handles live output streaming, timeout
    /// (SIGTERM/SIGKILL), cancellation registration, and the bounded-task
    /// semaphore.
    private func runProcessCore(
        executableURL: URL,
        arguments: [String],
        workingDirectory: String?,
        environmentVariables: [String: String]?,
        timeoutSeconds: Int,
        taskId: UUID,
        logId: UUID,
        ignoreExitCode: Bool = false,
        logFileWriter: LogFileWriter? = nil,
        captureLimitBytes: Int? = nil
    ) async -> ProcessResult {
        let isUnlimited = timeoutSeconds <= 0
        let control = executionControls[taskId] ?? ExecutionControl()
        let semaphore = executionSemaphore
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Wait off the main actor, with a cancellable queueing period.
                if !isUnlimited {
                    while semaphore.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                        if control.stopReason != nil {
                            continuation.resume(returning: ProcessResult(
                                stdout: "", stderr: "", exitCode: nil, status: .cancelled))
                            return
                        }
                    }
                }
                defer { if !isUnlimited { semaphore.signal() } }
                guard control.stopReason == nil else {
                    continuation.resume(returning: ProcessResult(
                        stdout: "", stderr: "", exitCode: nil, status: .cancelled))
                    return
                }

                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                if let dir = workingDirectory, !dir.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }
                if let envVars = environmentVariables {
                    process.environment = ProcessInfo.processInfo.environment.merging(envVars) { _, new in new }
                }
                let outputBuffer = PipeOutputBuffer(maximumBytes: captureLimitBytes ?? ExecutionLog.maxOutputSize)
                let batcher = IOBatcher(taskId: taskId)
                let scanner = NotificationDirectiveScanner()
                let gate = DirectiveNotificationGate()
                let fireDirective: @Sendable (NotificationDirective) -> Void = { directive in
                    DispatchQueue.main.async {
                        guard gate.count < DirectiveNotificationGate.maxPerRun,
                              UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
                        gate.count += 1
                        NotificationManager.shared.sendNotification(title: directive.title, body: directive.body ?? "")
                    }
                }
                func consume(_ data: Data, stdout: Bool) {
                    if stdout {
                        let (bytes, directives) = scanner.feed(data)
                        directives.forEach(fireDirective)
                        outputBuffer.appendStdout(bytes)
                        logFileWriter?.append(bytes)
                        batcher.appendStdout(bytes)
                    } else {
                        outputBuffer.appendStderr(data)
                        logFileWriter?.append(data)
                        batcher.appendStderr(data)
                    }
                }

                do { try process.run() } catch {
                    logFileWriter?.close()
                    continuation.resume(returning: ProcessResult(
                        stdout: "", stderr: "Failed to start process: \(error.localizedDescription)",
                        exitCode: nil, status: control.stopReason ?? .failure))
                    return
                }
                // Foundation creates the child in its own group on macOS.
                // Only signal a group whose ID belongs to this execution.
                let pid = process.processIdentifier
                let ownsGroup = getpgid(pid) == pid
                let capturedStart = ProcessReconciler.startTime(pid: pid)
                Task { @MainActor in
                    if self.activeLogs[taskId]?.id == logId {
                        self.runningProcesses[taskId] = process
                        self.persistRunningPID(logId: logId, pid: pid, startTime: capturedStart)
                    }
                }
                func signalTree(_ signal: Int32) {
                    if ownsGroup { kill(-pid, signal) }
                    if process.isRunning { kill(pid, signal) }
                }

                // One worker reads both pipes without blocking. A descendant that
                // inherits a pipe cannot pin readDataToEndOfFile indefinitely.
                let handles = [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
                for handle in handles {
                    let fd = handle.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                }
                defer { handles.forEach { try? $0.close() } }
                var eof = [false, false]
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                let started = ProcessInfo.processInfo.systemUptime
                var stoppingAt: TimeInterval?
                var exitedAt: TimeInterval?
                var sentKill = false
                while true {
                    for index in 0..<2 where !eof[index] {
                        // Bound each pass so a noisy stream cannot starve stop/deadline checks.
                        for _ in 0..<16 {
                            let count = read(handles[index].fileDescriptor, &bytes, bytes.count)
                            if count > 0 {
                                consume(Data(bytes.prefix(count)), stdout: index == 0)
                            } else {
                                if count == 0 || (errno != EAGAIN && errno != EINTR) { eof[index] = true }
                                break
                            }
                        }
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    let running = process.isRunning
                    if !running && exitedAt == nil { exitedAt = now }
                    if !running && eof.allSatisfy({ $0 }) && control.stopReason == nil { break }
                    if !isUnlimited && now - started >= Double(timeoutSeconds) {
                        control.requestStop(.timeout)
                    }
                    // A shell may exit leaving background children holding its pipes.
                    // Give trailing output a bounded grace period, then clean them up.
                    let drainExpired = exitedAt.map { now - $0 >= 3 } ?? false
                    if stoppingAt == nil && (control.stopReason != nil || drainExpired) {
                        stoppingAt = now
                        signalTree(SIGTERM)
                    }
                    if let stoppingAt, now - stoppingAt >= 3 && !sentKill {
                        signalTree(SIGKILL)
                        sentKill = true
                    }
                    if !running, let stoppingAt {
                        let groupAlive = ownsGroup && kill(-pid, 0) == 0
                        if eof.allSatisfy({ $0 }) && (!groupAlive || sentKill) { break }
                        if now - stoppingAt >= 3.5 { break }
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                process.waitUntilExit()
                let (tail, directives) = scanner.flush()
                directives.forEach(fireDirective)
                outputBuffer.appendStdout(tail)
                logFileWriter?.append(tail)
                batcher.appendStdout(tail)
                logFileWriter?.close()
                let (stdoutData, stderrData) = outputBuffer.read()
                let exitCode = Int(process.terminationStatus)
                let status = control.stopReason ?? (
                    process.terminationReason == .exit && (exitCode == 0 || ignoreExitCode)
                        ? ExecutionStatus.success : .failure)
                let result = ProcessResult(
                    stdout: cleanTerminalOutput(decodeProcessOutput(stdoutData)),
                    stderr: cleanTerminalOutput(decodeProcessOutput(stderrData)),
                    exitCode: exitCode, status: status)
                Task { @MainActor in
                    batcher.flushNow()
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
