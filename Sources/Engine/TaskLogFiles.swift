import Foundation
import SwiftData
import TaskTickCore

/// File ownership shared by history migration and the clear action.
enum TaskLogFiles {
    /// Upgrade database-only history in small batches on the main actor. Using
    /// the same context as Clear avoids a stale snapshot restoring cleared data.
    @MainActor
    static func backfillHistory(in container: ModelContainer) async {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ExecutionLog>(predicate: #Predicate {
            !$0.outputFileDeleted && $0.statusRaw != "running"
                && $0.task?.isManualOnly == false && $0.task?.isBackgroundService == false
        })
        guard let logs = try? context.fetch(descriptor) else { return }
        for (index, log) in logs.enumerated() {
            if Task.isCancelled { break }
            do {
                try materializeHistoryFile(for: log)
            } catch {
                NSLog("⚠️ History log file export failed: \(error)")
            }
            if (index + 1).isMultiple(of: 32) {
                do { try context.save() } catch { NSLog("⚠️ History log path save failed: \(error)") }
                await Task.yield()
            }
        }
        do { try context.save() } catch { NSLog("⚠️ History log path save failed: \(error)") }
    }

    @MainActor
    static func materializeHistoryFile(for log: ExecutionLog) throws {
        guard log.modelContext != nil, !log.outputFileDeleted,
              let task = log.task, !task.isBackgroundService, !task.isManualOnly,
              let url = LogFileWriter.executionFileURL(taskName: task.name, logId: log.id, startedAt: log.startedAt)
        else { return }
        if let path = log.outputFilePath {
            // Move completed files from the UUID folder or an earlier task
            // name. An active writer keeps its original path until it closes.
            let source = URL(fileURLWithPath: path)
            guard log.status != .running, source != url,
                  source.deletingLastPathComponent().deletingLastPathComponent() == LogFileWriter.logsDirectory(),
                  source.lastPathComponent == url.lastPathComponent else { return }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: url)
            } else if !FileManager.default.fileExists(atPath: url.path) {
                return
            }
            log.outputFilePath = url.path
            LogFileWriter.removeEmptyDirectory(source.deletingLastPathComponent())
            return
        }
        // An earlier interrupted export may already have created the file.
        // Preserve it, including an intentionally empty file.
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let output = [log.stdout, log.stderr].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
            let header = "Task: \(task.name)\nStarted: \(ISO8601DateFormatter().string(from: log.startedAt))\nTrigger: \(log.triggeredByRaw)\nStatus: \(log.statusRaw)\n\n"
            try Data((header + output).utf8).write(to: url, options: .atomic)
        }
        log.outputFilePath = url.path
    }

    @MainActor
    static func urls(for task: ScheduledTask) -> Set<URL> {
        var urls = Set(task.executionLogs.compactMap { log -> URL? in
            guard log.modelContext != nil, let path = log.outputFilePath else { return nil }
            return URL(fileURLWithPath: path)
        })
        // Name-based folders may contain another task's files. Ownership comes
        // from the saved execution paths, never from scanning the whole folder.
        // Include the default/legacy manual file, plus a service's custom path.
        var streamingURLs = [LogFileWriter.fileURL(for: task.name, taskId: task.id)].compactMap { $0 }
        if task.isBackgroundService, let path = task.serviceLogPath, !path.isEmpty {
            streamingURLs.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }
        for url in streamingURLs {
            urls.formUnion(LogFileWriter.filesIncludingArchives(at: url))
        }
        return urls
    }
}
