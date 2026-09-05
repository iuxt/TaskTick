import ArgumentParser
import Foundation
import TaskTickCore

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show the most recent execution log for a task."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Option(name: .long, help: "Number of lines from the end to show (0 = all).")
    var lines: Int = 0

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        let store = try ReadOnlyStore()
        let allTasks = try store.fetchTasks()
        let resolver = TaskResolver(
            items: allTasks,
            idOf: { $0.id },
            nameOf: { $0.name }
        )

        let task: ScheduledTask
        do {
            task = try resolver.resolve(identifier)
        } catch let err as TaskResolverError {
            FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
            throw ExitCode(1)
        }

        // If the task is currently running, hint at `tail` — fetchLatestLog
        // skips in-progress runs (their output isn't flushed to SwiftData yet),
        // so we'd otherwise show stale data without explanation.
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        if runningIds.contains(task.id) {
            FileHandle.standardError.write(Data(
                "note: \(task.name) is currently running — use `tail` for live output\n".utf8
            ))
        }

        guard let log = try store.fetchLatestLog(forTaskId: task.id) else {
            FileHandle.standardError.write(Data("tasktick: no execution logs for \(task.name)\n".utf8))
            throw ExitCode(1)
        }

        if json {
            let dto = ExecutionLogDTO(
                executionId: log.id,
                taskId: task.id,
                startedAt: log.startedAt,
                endedAt: log.finishedAt,
                exitCode: log.exitCode,
                stdout: log.stdout ?? "",
                stderr: log.stderr ?? "",
                lines: []  // Per-line timestamps not tracked in current schema; spec future-proofs the field.
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dto)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        // Human-readable: combine stdout + stderr with stream label, truncate to --lines.
        var out: [String] = []
        if let stdout = log.stdout, !stdout.isEmpty {
            out.append(contentsOf: stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        if let stderr = log.stderr, !stderr.isEmpty {
            for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("[stderr] \(line)")
            }
        }
        if lines > 0 && out.count > lines {
            out = Array(out.suffix(lines))
        }
        print(out.joined(separator: "\n"))
    }
}
