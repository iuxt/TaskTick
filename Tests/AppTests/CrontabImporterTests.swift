import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Crontab importer")
struct CrontabImporterTests {
    @Test("Environment and reboot macros are preserved")
    @MainActor
    func environmentAndRebootArePreserved() throws {
        let environment = [
            "SHELL": "/bin/zsh",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "CRON_TZ": "UTC",
        ]
        let entry = try #require(CrontabImporter.parseCrontabLine(
            "@reboot echo ready",
            environment: environment
        ))
        #expect(entry.cronExpression == "@reboot")
        #expect(entry.environment == environment)
        #expect(CrontabImporter.parseEnvironmentAssignment("PATH = '/a:/b'")?.value == "/a:/b")

        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        #expect(try CrontabImporter.importEntries([entry], into: container.mainContext) == 1)
        let task = try #require(container.mainContext.fetch(FetchDescriptor<ScheduledTask>()).first)
        #expect(task.shell == "/bin/zsh")
        #expect(task.environmentVariables == environment)
        #expect(task.timeZoneIdentifier == "UTC")
        #expect(task.runOnLaunch)
        #expect(task.nextRunAt == nil)
        #expect(task.isEnabled)
    }

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
