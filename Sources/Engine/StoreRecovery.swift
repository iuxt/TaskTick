import Foundation
import SQLite3
import SwiftData
import TaskTickCore

/// Builds a replacement independently of the recovery-mode memory container.
/// Original store files are preserved beside the database for manual recovery.
enum StoreRecovery {
    static func restore(_ tasks: [TaskExporter.ExportedTask], to storeURL: URL) throws {
        let fm = FileManager.default
        let parent = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".tasktick-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let sourceURL = staging.appendingPathComponent("source.store")
        let readyURL = staging.appendingPathComponent("ready.store")
        try buildSnapshot(tasks, sourceURL: sourceURL, destination: readyURL)

        let originals = parent.appendingPathComponent("recovery-original-\(UUID().uuidString)")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let files = ["", "-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
        // All copies must succeed before changing any live path.
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: originals.appendingPathComponent(file.lastPathComponent))
        }
        var moved: [URL] = []
        do {
            // The new main file is self-contained. Old WAL/SHM must not accompany it.
            for file in files.dropFirst() where fm.fileExists(atPath: file.path) {
                try fm.moveItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
                moved.append(file)
            }
            guard rename(readyURL.path, storeURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            for file in moved {
                try? fm.moveItem(at: staging.appendingPathComponent(file.lastPathComponent), to: file)
            }
            throw error
        }
    }

    private static func buildSnapshot(
        _ tasks: [TaskExporter.ExportedTask], sourceURL: URL, destination: URL
    ) throws {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let configuration = ModelConfiguration(schema: schema, url: sourceURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for item in tasks { context.insert(TaskExporter.makeTask(from: item)) }
        try context.save()
        // SQLite's backup API includes committed WAL pages even while SwiftData
        // still holds its connections. A filesystem copy of .store would not.
        var source: OpaquePointer?
        var target: OpaquePointer?
        defer { sqlite3_close(source); sqlite3_close(target) }
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw RecoveryError.snapshotFailed
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw RecoveryError.snapshotFailed }
    }

    enum RecoveryError: Error, LocalizedError {
        case snapshotFailed
        var errorDescription: String? { "Unable to create a persistent recovery database." }
    }
}
