import ArgumentParser
import Foundation
import TaskTickCore

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until a task completes; exit code mirrors the task's."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Option(name: .long, help: "Seconds to wait before timing out (0 = no timeout).")
    var timeout: Int = 0

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        let store = try ReadOnlyStore()
        let allTasks = try store.fetchTasks()
        let resolver = TaskResolver(
            items: allTasks,
            idOf: { $0.id },
            nameOf: { $0.name },
            serialOf: { $0.serialNumber }
        )

        let task: ScheduledTask
        do {
            task = try resolver.resolve(identifier)
        } catch let err as TaskResolverError {
            FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
            throw ExitCode(1)
        }

        // If task isn't running anymore, return its last exit code immediately.
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        if !runningIds.contains(task.id) {
            let lastLog = (try? store.fetchLatestLog(forTaskId: task.id)) ?? nil
            let code = lastLog?.exitCode ?? 0
            let dur = lastLog?.durationMs ?? 0
            printResult(name: task.name, exitCode: code, durationMs: dur, json: json)
            throw ExitCode(Int32(code))
        }

        // Subscribe to taskCompleted on the bundle-namespaced channel
        // (Phase 0.4 made the GUI broadcast names depend on Bundle.main).
        let bundleId = BundleContext.bundleID
        let completedName = Notification.Name("\(bundleId).gui.taskCompleted")
        let center = DistributedNotificationCenter.default()
        let targetId = task.id.uuidString
        let startedAt = Date()
        let useJSON = json
        let taskName = task.name
        let timeoutSeconds = timeout

        let exitCode: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let state = NotificationWaitState(center: center, continuation: cont)

            let observer = center.addObserver(forName: completedName, object: nil, queue: .main) { note in
                guard let id = note.userInfo?["id"] as? String, id == targetId else { return }
                let exit = (note.userInfo?["exitCode"] as? Int) ?? 0
                if state.finish(with: .success(Int32(exit))) {
                    let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    printResult(name: taskName, exitCode: exit, durationMs: durMs, json: useJSON)
                }
            }
            state.installObserver(observer)

            if timeoutSeconds > 0 {
                let work = DispatchWorkItem {
                    if state.finish(with: .failure(ExitCode(124))) {
                        FileHandle.standardError.write(Data("tasktick: timed out after \(timeoutSeconds)s\n".utf8))
                    }
                }
                state.installTimeoutWorkItem(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: work)
            }
        }
        throw ExitCode(exitCode)
    }
}

private func printResult(name: String, exitCode: Int, durationMs: Int, json: Bool) {
    if json {
        let payload: [String: Any] = [
            "name": name,
            "exitCode": exitCode,
            "durationMs": durationMs
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        let dur = durationMs >= 1000 ? "\(durationMs / 1000)s" : "\(durationMs)ms"
        print("✓ Completed in \(dur) (exit \(exitCode))")
    }
}
