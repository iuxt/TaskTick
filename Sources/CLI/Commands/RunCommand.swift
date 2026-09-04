import ArgumentParser
import Foundation
import TaskTickCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start a task. Wakes TaskTick.app if not running."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long, help: "Block until the task completes, streaming its output. Exit code mirrors the task's.")
    var wait: Bool = false

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        if wait {
            try await runAndWait(identifier: identifier, json: json)
        } else {
            try await dispatch(action: .run, identifier: identifier, json: json)
        }
    }
}

/// Shared dispatch logic for run/stop/restart/reveal — they only differ by
/// CLIAction enum value and the success message verb.
@MainActor
func dispatch(action: NotificationBridge.CLIAction, identifier: String, json: Bool) async throws {
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

    // Idempotency: already-running guard for run, idle guard for stop.
    let runningIds = NotificationBridge.runningTaskIds(store: store)
    let isRunning = runningIds.contains(task.id)
    switch action {
    case .run where isRunning:
        FileHandle.standardError.write(Data("note: already running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    case .stop where !isRunning:
        FileHandle.standardError.write(Data("note: not running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    default:
        break
    }

    if GUILauncher.isRunning() {
        NotificationBridge.post(action: action, taskId: task.id)
    } else {
        // Wake the GUI and let it process the URL Scheme directly.
        let ok = GUILauncher.launchAndWait(action: action, taskId: task.id)
        if !ok {
            FileHandle.standardError.write(Data("tasktick: TaskTick.app failed to launch within 10s\n".utf8))
            throw ExitCode(1)
        }
    }
    printSuccess(action: action, name: task.name, json: json)
}

private func printSuccess(action: NotificationBridge.CLIAction, name: String, json: Bool) {
    if json {
        let payload: [String: String] = [
            "id": action.rawValue,
            "status": {
                switch action {
                case .run: return "started"
                case .stop: return "stopped"
                case .restart: return "restarted"
                case .reveal: return "revealed"
                }
            }(),
            "name": name
        ]
        let data = try? JSONEncoder().encode(payload)
        print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    } else {
        let verb: String = {
            switch action {
            case .run: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            case .reveal: return "Revealed in TaskTick"
            }
        }()
        print("✓ \(verb): \(name)")
    }
}

/// `run --wait` — combines run + tail + exit-code-passthrough into one
/// invocation. Subscribes to `gui.logChunk` + `gui.taskCompleted` BEFORE
/// dispatching the run notification (avoids losing first-frame output).
///
/// Started/Completed banners go to stderr so `run X --wait` pipes cleanly:
/// stdout is just the task's output. Ctrl+C exits the CLI watcher with 130;
/// the task continues in the GUI.
@MainActor
func runAndWait(identifier: String, json: Bool) async throws {
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

    let bundleId = BundleContext.bundleID
    let chunkName = Notification.Name("\(bundleId).gui.logChunk")
    let completedName = Notification.Name("\(bundleId).gui.taskCompleted")
    let center = DistributedNotificationCenter.default()
    let targetId = task.id.uuidString
    let startedAt = Date()
    let taskName = task.name
    let useJSON = json

    // Print "Started" line on stderr so stdout is just the task's output.
    FileHandle.standardError.write(Data("✓ Started: \(taskName)\n".utf8))

    let exitCode: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
        let state = NotificationWaitState(center: center, continuation: cont)

        // Ctrl+C handler — task continues in GUI; CLI just stops watching.
        signal(SIGINT, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSrc.setEventHandler {
            state.fail(with: ExitCode(130))
        }
        state.installSignalSource(sigSrc)
        sigSrc.resume()

        // Subscribe to chunks BEFORE dispatching to avoid losing first lines.
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
                if stream == "stderr" {
                    FileHandle.standardError.write(Data(("[stderr] " + text).utf8))
                } else {
                    print(text, terminator: "")
                }
            }
        }
        state.installObserver(chunkObserver)

        let completedObserver = center.addObserver(forName: completedName, object: nil, queue: .main) { note in
            guard let id = note.userInfo?["id"] as? String, id == targetId else { return }
            let exit = (note.userInfo?["exitCode"] as? Int) ?? 0
            if state.succeed(with: Int32(exit)) {
                let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let dur = durMs >= 1000 ? "\(durMs / 1000)s" : "\(durMs)ms"
                FileHandle.standardError.write(Data("✓ Completed in \(dur) (exit \(exit))\n".utf8))
            }
        }
        state.installObserver(completedObserver)

        // Now dispatch run — observer is already listening.
        if GUILauncher.isRunning() {
            NotificationBridge.post(action: .run, taskId: task.id)
        } else {
            let ok = GUILauncher.launchAndWait(action: .run, taskId: task.id)
            if !ok {
                if state.fail(with: ExitCode(1)) {
                    FileHandle.standardError.write(Data("tasktick: TaskTick.app failed to launch within 10s\n".utf8))
                }
                return
            }
        }
    }

    throw ExitCode(exitCode)
}
