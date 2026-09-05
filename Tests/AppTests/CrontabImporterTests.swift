import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Crontab importer")
struct CrontabImporterTests {
    @Test("Imported entries receive an initial next run date")
    @MainActor
    func importedTaskIsImmediatelyScheduled() throws {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let entry = CrontabImporter.CrontabEntry(
            cronExpression: "* * * * *",
            command: "echo ready",
            originalLine: "* * * * * echo ready"
        )

        #expect(try CrontabImporter.importEntries([entry], into: container.mainContext) == 1)
        let task = try #require(container.mainContext.fetch(FetchDescriptor<ScheduledTask>()).first)
        #expect(task.nextRunAt != nil)
        #expect(task.nextRunAt! > Date())
    }
}
