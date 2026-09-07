import Foundation
import SwiftData
import TaskTickCore

/// Imports tasks from the system crontab.
struct CrontabImporter {

    struct CrontabEntry: Sendable {
        let cronExpression: String
        let command: String
        let originalLine: String
        let environment: [String: String]

        init(
            cronExpression: String,
            command: String,
            originalLine: String,
            environment: [String: String] = [:]
        ) {
            self.cronExpression = cronExpression
            self.command = command
            self.originalLine = originalLine
            self.environment = environment
        }
    }

    /// Read current user's crontab entries
    static func readCrontab() async -> [CrontabEntry] {
        await Task.detached(priority: .userInitiated) {
            readCrontabBlocking()
        }.value
    }

    private static func readCrontabBlocking() -> [CrontabEntry] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // Drain while the child is running. Waiting first can deadlock when a
        // large crontab fills the pipe and blocks the child before it exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [CrontabEntry] = []
        var environment: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let assignment = parseEnvironmentAssignment(trimmed) {
                environment[assignment.name] = assignment.value
                continue
            }

            if let entry = parseCrontabLine(trimmed, environment: environment) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Parse a single crontab line into cron expression + command
    static func parseCrontabLine(
        _ line: String,
        environment: [String: String] = [:]
    ) -> CrontabEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") {
            let parts = trimmed.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard parts.count == 2 else { return nil }
            let macro = String(parts[0]).lowercased()
            let command = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            let expression: String
            switch macro {
            case "@reboot": expression = "@reboot"
            case "@yearly", "@annually": expression = "0 0 1 1 *"
            case "@monthly": expression = "0 0 1 * *"
            case "@weekly": expression = "0 0 * * 0"
            case "@daily", "@midnight": expression = "0 0 * * *"
            case "@hourly": expression = "0 * * * *"
            default: return nil
            }
            return CrontabEntry(
                cronExpression: expression,
                command: command,
                originalLine: trimmed,
                environment: environment
            )
        }

        let parts = trimmed.split(
            maxSplits: 5,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard parts.count >= 6 else { return nil }

        let cronFields = parts[0..<5].joined(separator: " ")
        let command = String(parts[5...].joined(separator: " "))

        guard (try? CronExpression(parsing: cronFields)) != nil else { return nil }

        return CrontabEntry(
            cronExpression: cronFields,
            command: command.trimmingCharacters(in: .whitespaces),
            originalLine: trimmed,
            environment: environment
        )
    }

    /// Crontab assignments apply to all following entries. Preserve quoted
    /// values and optional whitespace around `=` instead of silently dropping
    /// PATH, SHELL, locale and application-specific variables during import.
    static func parseEnvironmentAssignment(_ line: String) -> (name: String, value: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first),
              name.unicodeScalars.dropFirst().allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
              }) else { return nil }
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")
            || value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return (name, value)
    }

    /// Convert a cron expression to the new RepeatType (best effort)
    static func cronToRepeatType(_ cron: String) -> (repeatType: RepeatType, date: Date?) {
        let calendar = Calendar.current
        let now = Date()

        switch cron {
        case "* * * * *":
            return (.everyMinute, now)
        case "*/5 * * * *":
            return (.every5Minutes, now)
        case "*/15 * * * *":
            return (.every15Minutes, now)
        case "*/30 * * * *":
            return (.every30Minutes, now)
        case let c where c.hasPrefix("0 ") && c.hasSuffix(" * * *"):
            // "0 N * * *" → daily at N:00
            let parts = c.split(separator: " ")
            if parts.count == 5, let hour = Int(parts[1]) {
                var comps = calendar.dateComponents([.year, .month, .day], from: now)
                comps.hour = hour
                comps.minute = 0
                let date = calendar.date(from: comps) ?? now
                return (.daily, date)
            }
            return (.daily, now)
        case let c where c.contains("* * 1"):
            // Weekly Monday
            return (.weekly, now)
        case let c where c.contains("* * 0"):
            // Weekly Sunday
            return (.weekly, now)
        default:
            // For complex expressions, try to parse minute/hour for daily
            let parts = cron.split(separator: " ")
            if parts.count == 5,
               let minute = Int(parts[0]),
               let hour = Int(parts[1]),
               parts[2] == "*", parts[3] == "*", parts[4] == "*" {
                var comps = calendar.dateComponents([.year, .month, .day], from: now)
                comps.hour = hour
                comps.minute = minute
                let date = calendar.date(from: comps) ?? now
                return (.daily, date)
            }
            // Fallback: use hourly with legacy cron
            return (.hourly, now)
        }
    }

    /// Import crontab entries as ScheduledTask objects.
    /// Throws the underlying save error so the caller can present UI;
    /// this keeps the importer free of AppKit/UI dependencies.
    @MainActor
    static func importEntries(_ entries: [CrontabEntry], into context: ModelContext) throws -> Int {
        var imported = 0
        var insertedTasks: [ScheduledTask] = []
        for entry in entries {
            let isReboot = entry.cronExpression == "@reboot"
            let scheduleInfo: (repeatType: RepeatType, date: Date?) = isReboot
                ? (RepeatType.never, nil)
                : cronToRepeatType(entry.cronExpression)

            // Generate a name from the command
            let name = generateTaskName(from: entry.command)

            let task = ScheduledTask(
                name: name,
                scriptBody: entry.command,
                shell: entry.environment["SHELL"] ?? "/bin/bash",
                scheduledDate: scheduleInfo.date,
                repeatType: scheduleInfo.repeatType,
                endRepeatType: .never,
                isEnabled: true,
                notifyOnFailure: true
            )
            task.environmentVariables = entry.environment.isEmpty ? nil : entry.environment
            if let cronTimeZone = entry.environment["CRON_TZ"],
               TimeZone(identifier: cronTimeZone) != nil {
                task.timeZoneIdentifier = cronTimeZone
            }
            if isReboot {
                task.runOnLaunch = true
                task.schedule = .interval
                task.cronExpression = nil
                task.nextRunAt = nil
            } else {
                // Store original cron for reference and exact scheduling.
                task.cronExpression = entry.cronExpression
                task.schedule = .cron
                task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
            }

            context.insert(task)
            insertedTasks.append(task)
            imported += 1
        }
        do {
            try context.save()
        } catch {
            // Surgically delete the pending inserts rather than calling rollback(),
            // which would also revert unrelated concurrent edits on the same context.
            for task in insertedTasks {
                context.delete(task)
            }
            throw error
        }
        return imported
    }

    /// Comment out specified lines in the crontab
    static func commentOutEntries(_ entries: [CrontabEntry]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            commentOutEntriesBlocking(entries)
        }.value
    }

    private static func commentOutEntriesBlocking(_ entries: [CrontabEntry]) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard var content = String(data: data, encoding: .utf8) else { return false }

        let originalLines = Set(entries.map(\.originalLine))

        // Comment out matching lines
        let lines = content.components(separatedBy: "\n")
        let updatedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if originalLines.contains(trimmed) {
                return "# [TaskTick imported] " + line
            }
            return line
        }
        content = updatedLines.joined(separator: "\n")

        // Write back
        let writeProcess = Process()
        let inputPipe = Pipe()
        writeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        writeProcess.arguments = ["-"]
        writeProcess.standardInput = inputPipe

        do {
            try writeProcess.run()
            guard let data = content.data(using: .utf8) else { return false }
            inputPipe.fileHandleForWriting.write(data)
            inputPipe.fileHandleForWriting.closeFile()
            writeProcess.waitUntilExit()
            return writeProcess.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Generate a readable task name from the command
    private static func generateTaskName(from command: String) -> String {
        // Take the first meaningful part of the command
        let cleaned = command
            .replacingOccurrences(of: "&&", with: " ")
            .replacingOccurrences(of: "||", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: ";", with: " ")

        let firstCommand = cleaned.split(separator: " ").first.map(String.init) ?? command

        // Extract just the binary name
        let binary = (firstCommand as NSString).lastPathComponent

        if binary.isEmpty {
            return "Imported Task"
        }
        return "crontab: \(binary)"
    }
}
