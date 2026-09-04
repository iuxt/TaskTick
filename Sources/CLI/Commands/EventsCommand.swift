import ArgumentParser
import Foundation
import TaskTickCore

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Stream task lifecycle events as NDJSON. Long-running."
    )

    @MainActor
    func run() async throws {
        let bundleId = BundleContext.bundleID
        let startedName = Notification.Name("\(bundleId).gui.taskStarted")
        let completedName = Notification.Name("\(bundleId).gui.taskCompleted")
        let center = DistributedNotificationCenter.default()
        // Ctrl+C → exit 130 (Unix convention).
        signal(SIGINT, SIG_IGN)
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSrc.setEventHandler { Foundation.exit(130) }
        intSrc.resume()

        // SIGTERM → clean exit 0 (Raycast extension calling proc.kill).
        signal(SIGTERM, SIG_IGN)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSrc.setEventHandler { Foundation.exit(0) }
        termSrc.resume()

        let onStarted: @Sendable (Notification) -> Void = { note in
            guard let info = note.userInfo,
                  let id = info["id"] as? String else { return }
            let executionId = (info["executionId"] as? String) ?? ""
            let ts = (info["startedAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
            let line = Self.formatStartedLine(id: id, executionId: executionId, ts: ts)
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
        let onCompleted: @Sendable (Notification) -> Void = { note in
            guard let info = note.userInfo,
                  let id = info["id"] as? String else { return }
            let executionId = (info["executionId"] as? String) ?? ""
            let exitCode = (info["exitCode"] as? Int) ?? 0
            let ts = (info["endedAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
            let line = Self.formatCompletedLine(id: id, executionId: executionId, exitCode: exitCode, ts: ts)
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }

        center.addObserver(forName: startedName,   object: nil, queue: .main, using: onStarted)
        center.addObserver(forName: completedName, object: nil, queue: .main, using: onCompleted)

        // Park forever; signal handlers above call Foundation.exit() to terminate
        // the process. The continuation is intentionally never resumed.
        // Reference the dispatch sources so they aren't deallocated.
        _ = intSrc
        _ = termSrc
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
            // Never resume; signal handlers (SIGINT/SIGTERM) call Foundation.exit().
            // Using unsafe to avoid the runtime leak warning at process exit.
        }
    }

    /// Pure formatter — testable without subscribing.
    static func formatStartedLine(id: String, executionId: String, ts: String) -> String {
        let payload: [String: Any] = ["type": "started", "id": id, "executionId": executionId, "ts": ts]
        return Self.encode(payload)
    }

    static func formatCompletedLine(id: String, executionId: String, exitCode: Int, ts: String) -> String {
        let payload: [String: Any] = ["type": "completed", "id": id, "executionId": executionId, "exitCode": exitCode, "ts": ts]
        return Self.encode(payload)
    }

    private static func encode(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return s + "\n"
    }
}
