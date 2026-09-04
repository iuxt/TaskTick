import ArgumentParser
import Foundation
import TaskTickCore

struct TailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Stream a running task's stdout/stderr in real time."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

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

        // Refuse early if the task isn't currently running — there's nothing
        // to stream.
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        guard runningIds.contains(task.id) else {
            FileHandle.standardError.write(Data("tasktick: \(task.name) is not running\n".utf8))
            throw ExitCode(1)
        }

        // Subscribe to chunk + completed notifications. Dynamic per-bundle
        // so dev CLI (inside dev .app) listens on the dev GUI's namespace.
        let center = DistributedNotificationCenter.default()
        let bundleId = BundleContext.bundleID
        let chunkName     = Notification.Name("\(bundleId).gui.logChunk")
        let completedName = Notification.Name("\(bundleId).gui.taskCompleted")
        let targetId = task.id.uuidString
        let useJSON = json

        // Use a Continuation to bridge Distributed Notifications into async/await.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let state = NotificationWaitState(center: center, continuation: cont)

            // Install signal handler for Ctrl+C → exit 130.
            signal(SIGINT, SIG_IGN)
            let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigSrc.setEventHandler {
                state.finish(with: .failure(ExitCode(130)))
            }
            state.installSignalSource(sigSrc)
            sigSrc.resume()

            let chunkObserver = center.addObserver(forName: chunkName, object: nil, queue: .main) { note in
                guard
                    let info = note.userInfo,
                    let id = info["id"] as? String,
                    id == targetId,
                    let stream = info["stream"] as? String,
                    let text = info["text"] as? String
                else { return }
                if useJSON {
                    let payload: [String: String] = ["stream": stream, "text": text]
                    if let data = try? JSONEncoder().encode(payload),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                    }
                } else {
                    let prefix = (stream == "stderr") ? "[stderr] " : ""
                    print(prefix + text, terminator: "")
                }
            }
            state.installObserver(chunkObserver)

            let completedObserver = center.addObserver(forName: completedName, object: nil, queue: .main) { note in
                guard let id = note.userInfo?["id"] as? String, id == targetId else { return }
                state.finish(with: .success(()))
            }
            state.installObserver(completedObserver)
        }
    }
}
