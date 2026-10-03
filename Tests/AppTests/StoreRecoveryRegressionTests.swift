import Foundation
import SQLite3
import SwiftData
import Testing
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("Store recovery and migration regressions")
struct StoreRecoveryRegressionTests {
    @Test("Failed migration explicitly requests recovery and preserves legacy data")
    func migrationFailureIsExplicit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let namespace = root.appendingPathComponent("test.bundle")
        try Data("legacy-data".utf8).write(to: legacy)
        // Deterministic directory creation failure without permission assumptions.
        try Data("blocking-file".utf8).write(to: namespace)
        let result = StoreMigration.resolveStore(appSupport: root, bundleID: "test.bundle", filename: "default.store")
        #expect(result.requiresRecovery)
        #expect(result.url == namespace.appendingPathComponent("default.store"))
        #expect(!FileManager.default.fileExists(atPath: result.url.path))
        #expect(try Data(contentsOf: legacy) == Data("legacy-data".utf8))
        #expect(try Data(contentsOf: namespace) == Data("blocking-file".utf8))
    }

    @Test("Migration copies all sidecars, preserves legacy files and is idempotent")
    func successfulMigration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["", "-wal", "-shm"] {
            try Data("legacy\(suffix)".utf8).write(to: root.appendingPathComponent("default.store" + suffix))
        }
        let result = StoreMigration.resolveStore(appSupport: root, bundleID: "test.bundle", filename: "default.store")
        #expect(!result.requiresRecovery)
        for suffix in ["", "-wal", "-shm"] {
            let expected = Data("legacy\(suffix)".utf8)
            #expect(try Data(contentsOf: root.appendingPathComponent("default.store" + suffix)) == expected)
            #expect(try Data(contentsOf: URL(fileURLWithPath: result.url.path + suffix)) == expected)
        }
        let second = StoreMigration.resolveStore(appSupport: root, bundleID: "test.bundle", filename: "default.store")
        #expect(!second.requiresRecovery)
        #expect(second.url == result.url)
    }

    @Test("Interrupted migration refuses ambiguous sidecars without opening a new store")
    func interruptedMigrationRequestsRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("legacy".utf8).write(to: root.appendingPathComponent("default.store"))
        let directory = root.appendingPathComponent("test.bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wal = directory.appendingPathComponent("default.store-wal")
        try Data("interrupted-wal".utf8).write(to: wal)
        let result = StoreMigration.resolveStore(appSupport: root, bundleID: "test.bundle", filename: "default.store")
        #expect(result.requiresRecovery)
        #expect(!FileManager.default.fileExists(atPath: result.url.path))
        #expect(try Data(contentsOf: wal) == Data("interrupted-wal".utf8))
    }

    @Test("Invalid or missing legacy backups leave all live files untouched")
    func invalidLegacyDoesNotTouchLiveStore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live.store")
        let source = root.appendingPathComponent("backup.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("live\(suffix)".utf8).write(to: URL(fileURLWithPath: live.path + suffix))
        }
        for exists in [false, true] {
            if exists { try Data("not a SQLite database".utf8).write(to: source) }
            #expect(throws: (any Error).self) { try StoreRecovery.restoreLegacy(from: source, to: live) }
            for suffix in ["", "-wal", "-shm"] {
                #expect(try Data(contentsOf: URL(fileURLWithPath: live.path + suffix)) == Data("live\(suffix)".utf8))
            }
        }
    }

    @Test("Legacy recovery snapshots committed WAL data and preserves the old store")
    @MainActor
    func legacyWALRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("backup.store")
        let live = root.appendingPathComponent("live.store")
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let sourceContainer = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, url: source)])
        let task = ScheduledTask(name: "From WAL", scriptBody: "echo restored")
        task.scheduleAnchorTimeZoneIdentifier = "GMT"
        sourceContainer.mainContext.insert(task)
        try sourceContainer.mainContext.save()
        #expect(FileManager.default.fileExists(atPath: source.path + "-wal"))
        let originalMain = try Data(contentsOf: source)
        let originalWAL = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        let original = Data("original live main".utf8)
        try original.write(to: live)
        for suffix in ["-wal", "-shm"] {
            try Data("old\(suffix)".utf8).write(to: URL(fileURLWithPath: live.path + suffix))
        }
        try StoreRecovery.restoreLegacy(from: source, to: live)
        #expect(!FileManager.default.fileExists(atPath: live.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: live.path + "-shm"))
        #expect(try Data(contentsOf: source) == originalMain)
        #expect(try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")) == originalWAL)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("recovery-original-") }))
        #expect(try Data(contentsOf: preserved.appendingPathComponent(live.lastPathComponent)) == original)
        #expect(try Data(contentsOf: preserved.appendingPathComponent(live.lastPathComponent + "-wal")) == Data("old-wal".utf8))
        let restored = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, url: live)])
        let tasks = try restored.mainContext.fetch(FetchDescriptor<ScheduledTask>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.name == "From WAL")
        #expect(tasks.first?.scheduleAnchorTimeZoneIdentifier == "GMT")
    }

    @Test("Failed atomic replacement rolls the live sidecars back")
    @MainActor
    func failedInstallationRollsBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("backup.store")
        try StoreRecovery.restore([TaskExporter.makeExported(ScheduledTask(name: "restored"))], to: backup)
        // A main-path directory makes the final rename fail after staging sidecars.
        let live = root.appendingPathComponent("live.store")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let marker = live.appendingPathComponent("keep")
        try Data("original".utf8).write(to: marker)
        for suffix in ["-wal", "-shm"] {
            try Data("live\(suffix)".utf8).write(to: URL(fileURLWithPath: live.path + suffix))
        }
        #expect(throws: (any Error).self) { try StoreRecovery.restoreLegacy(from: backup, to: live) }
        #expect(try Data(contentsOf: marker) == Data("original".utf8))
        for suffix in ["-wal", "-shm"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: live.path + suffix)) == Data("live\(suffix)".utf8))
        }
    }

    @Test("A valid SQLite file without TaskTick tables is rejected")
    func unrelatedSQLiteIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("foreign.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE other (value TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let live = root.appendingPathComponent("live.store")
        try Data("original".utf8).write(to: live)
        #expect(throws: (any Error).self) { try StoreRecovery.restoreLegacy(from: source, to: live) }
        #expect(try Data(contentsOf: live) == Data("original".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasktick-store-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
