import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Database backup safety")
struct DatabaseBackupSafetyTests {
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
