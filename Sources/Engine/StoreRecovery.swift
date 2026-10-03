import Foundation
import SQLite3
import SwiftData
import TaskTickCore

/// Stages and validates replacements before touching the live database.
/// Original store files are preserved beside the database for manual recovery.
enum StoreRecovery {
    static func restore(_ tasks: [TaskExporter.ExportedTask], to storeURL: URL) throws {
        try withStaging(at: storeURL) { staging in
            let source = staging.appendingPathComponent("source.store")
            let schema = Schema([ScheduledTask.self, ExecutionLog.self])
            let configuration = ModelConfiguration(schema: schema, url: source)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            for item in tasks { context.insert(TaskExporter.makeTask(from: item)) }
            try context.save()
            let ready = staging.appendingPathComponent("ready.store")
            try snapshot(from: source, to: ready)
            try install(ready, at: storeURL, staging: staging)
        }
    }

    static func restoreLegacy(from backupURL: URL, to storeURL: URL) throws {
        try withStaging(at: storeURL) { staging in
            let source = staging.appendingPathComponent("source.store")
            let fm = FileManager.default
            // Copy WAL too: committed data may not yet be in the main file.
            // SHM is rebuilt locally, so the backup itself is never modified.
            try fm.copyItem(at: backupURL, to: source)
            let wal = URL(fileURLWithPath: backupURL.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: source.path + "-wal"))
            }
            let ready = staging.appendingPathComponent("ready.store")
            try snapshot(from: source, to: ready)
            try install(ready, at: storeURL, staging: staging)
        }
    }

    private static func withStaging(at storeURL: URL, body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let parent = storeURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".tasktick-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try body(staging)
    }

    private static func install(_ ready: URL, at storeURL: URL, staging: URL) throws {
        let fm = FileManager.default
        let originals = storeURL.deletingLastPathComponent()
            .appendingPathComponent("recovery-original-\(UUID().uuidString)")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let files = ["", "-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
        // All preservation copies must succeed before changing any live path.
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: originals.appendingPathComponent(file.lastPathComponent))
        }
        var moved: [URL] = []
        do {
            for file in files.dropFirst() where fm.fileExists(atPath: file.path) {
                try fm.moveItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
                moved.append(file)
            }
            // Atomic main-file replacement is the final, committing operation.
            guard rename(ready.path, storeURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            var rollbackFailed = false
            for file in moved {
                let staged = staging.appendingPathComponent(file.lastPathComponent)
                do {
                    try fm.moveItem(at: staged, to: file)
                } catch {
                    // The preservation copy remains even if rollback is blocked.
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw RecoveryError.rollbackFailed(originals) }
            throw error
        }
    }

    private static func snapshot(from sourceURL: URL, to destination: URL) throws {
        // SQLite backup includes committed WAL pages while SwiftData is open.
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
        var check: OpaquePointer?
        defer { sqlite3_finalize(check) }
        guard sqlite3_prepare_v2(target, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK,
              sqlite3_step(check) == SQLITE_ROW,
              let result = sqlite3_column_text(check, 0), String(cString: result) == "ok" else {
            throw RecoveryError.snapshotFailed
        }
        var schema: OpaquePointer?
        defer { sqlite3_finalize(schema) }
        guard sqlite3_prepare_v2(target,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('ZSCHEDULEDTASK','ZEXECUTIONLOG')",
            -1, &schema, nil) == SQLITE_OK,
              sqlite3_step(schema) == SQLITE_ROW, sqlite3_column_int(schema, 0) == 2 else {
            throw RecoveryError.snapshotFailed
        }
    }

    enum RecoveryError: Error, LocalizedError {
        case snapshotFailed
        case rollbackFailed(URL)
        var errorDescription: String? {
            switch self {
            case .snapshotFailed: "Unable to create a valid TaskTick recovery database."
            case .rollbackFailed(let url): "Rollback failed. Original database files are preserved at \(url.path)."
            }
        }
    }
}
