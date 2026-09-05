import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Database backup safety")
struct DatabaseBackupSafetyTests {
    @Test("Dedup follows surviving backup contents after the newest file is deleted")
    @MainActor
    func deletedLatestBackupDoesNotHideChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let task = ScheduledTask(name: "A", scriptBody: "echo A")
        let old = TaskExporter.makeExported(task)
        task.scriptBody = "echo B"
        let current = TaskExporter.makeExported(task)
        let hash = try #require(DatabaseBackup.computeContentHash(tasks: [current]))
        let olderURL = root.appendingPathComponent("older.tasktickbackup")
        let latestURL = root.appendingPathComponent("latest.tasktickbackup")
        try writeBackup([old], to: olderURL)
        try writeBackup([current], to: latestURL)

        #expect(DatabaseBackup.backup(at: latestURL, matchesContentHash: hash))
        try FileManager.default.removeItem(at: latestURL)
        #expect(!DatabaseBackup.backup(at: latestURL, matchesContentHash: hash))
        #expect(!DatabaseBackup.backup(at: olderURL, matchesContentHash: hash))

        // A stale header cannot make a different or corrupt payload a match.
        try writeBackup([old], to: olderURL, headerHash: hash)
        #expect(!DatabaseBackup.backup(at: olderURL, matchesContentHash: hash))
        try Data("invalid JSON".utf8).write(to: olderURL)
        #expect(!DatabaseBackup.backup(at: olderURL, matchesContentHash: hash))
    }

    @MainActor
    private func writeBackup(
        _ tasks: [TaskExporter.ExportedTask], to url: URL, headerHash: String? = nil
    ) throws {
        let payload = BackupPayload(
            format: BackupPayload.currentFormat, appVersion: "test",
            exportDate: Date(), taskCount: tasks.count, tasks: tasks, contentHash: headerHash
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: url)
    }

    @Test("Pruning leaves unrelated directories untouched")
    @MainActor
    func unrelatedDirectoriesSurvivePruning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-prune-\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent("personal-files")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: unrelated.appendingPathComponent("document.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        DatabaseBackup.pruneOldBackups(
            in: root, keeping: 1, legacyStoreName: "default.store"
        )

        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(
            atPath: unrelated.appendingPathComponent("document.txt").path
        ))
    }

    @Test("Recovery creates a persistent store with restored tasks")
    @MainActor
    func recoveryWritesPersistentStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-recovery-\(UUID().uuidString)")
        let storeURL = root.appendingPathComponent("default.store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ScheduledTask(name: "Recovered", scriptBody: "echo restored")
        original.environmentVariables = ["RECOVERED": "yes"]

        try StoreRecovery.restore([TaskExporter.makeExported(original)], to: storeURL)

        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let tasks = try container.mainContext.fetch(FetchDescriptor<ScheduledTask>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.name == "Recovered")
        #expect(tasks.first?.environmentVariables == ["RECOVERED": "yes"])
    }
}
