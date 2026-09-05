import ArgumentParser
import Foundation
import TaskTickCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show running tasks (no arg: global summary; with arg: single task)."
    )

    @Argument(help: "Task identifier (UUID, prefix, name, or fuzzy).")
    var identifier: String?

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        let store = try ReadOnlyStore()
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        let allTasks = try store.fetchTasks()

        if let id = identifier {
            let resolver = TaskResolver(
                items: allTasks,
                idOf: { $0.id },
                nameOf: { $0.name },
                serialOf: { $0.serialNumber }
            )
            let task: ScheduledTask
            do {
                task = try resolver.resolve(id)
            } catch let err as TaskResolverError {
                FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
                throw ExitCode(1)
            }
            let lastLog = (try? store.fetchLatestLog(forTaskId: task.id)) ?? nil
            let dto = TaskDTO.from(task, runningIds: runningIds, lastLog: lastLog)
            if json {
                try printJSON(dto)
            } else {
                print("\(dto.shortId)  \(dto.name)  [\(dto.status.rawValue)]")
            }
            return
        }

        // Global summary
        let runningTasks = allTasks.filter { runningIds.contains($0.id) }
        let runningDTOs: [StatusGlobalDTO.RunningTask] = runningTasks.compactMap { task in
            guard let log = try? store.fetchRunningLog(forTaskId: task.id) else { return nil }
            let elapsed = Int(Date().timeIntervalSince(log.startedAt))
            return .init(id: task.id, name: task.name, startedAt: log.startedAt, elapsedSec: elapsed)
        }
        let global = StatusGlobalDTO(
            running: runningDTOs,
            totalEnabled: allTasks.filter(\.isEnabled).count,
            totalRunning: runningDTOs.count
        )

        if json {
            try printJSON(global)
        } else {
            print("Enabled: \(global.totalEnabled)  Running: \(global.totalRunning)")
            for t in runningDTOs {
                print("  \(t.name) — \(t.elapsedSec)s")
            }
        }
    }

    private func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}
