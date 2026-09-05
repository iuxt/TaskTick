import Foundation
import Testing
import TaskTickCore
@testable import TaskTickApp

struct TaskExporterTests {
    @Test("Round trip preserves execution and schedule options")
    func preservesAllBehaviorSettings() {
        let task = ScheduledTask(name: "Configured", scriptBody: "echo ok")
        task.environmentVariables = ["TOKEN": "local-value"]
        task.notifyOnAction = true
        task.hasDate = false
        task.hasTime = false

        let restored = TaskExporter.makeTask(from: TaskExporter.makeExported(task))

        #expect(restored.environmentVariables == ["TOKEN": "local-value"])
        #expect(restored.notifyOnAction)
        #expect(!restored.hasDate)
        #expect(!restored.hasTime)
    }

    @Test("Older backups preserve task settings and discard retired notification fields")
    func importsLegacyNotificationSettings() throws {
        let data = Data(#"""
        {
            "name": "Legacy task",
            "serialNumber": 99,
            "scriptBody": "echo hello",
            "shell": "/bin/zsh",
            "repeatType": "daily",
            "endRepeatType": "never",
            "timeoutSeconds": 120,
            "notifyOnSuccess": false,
            "notifyOnFailure": true,
            "notifyOnlyWhenOutput": true,
            "isEnabled": true,
            "strongReminder": true,
            "notificationTemplateEnabled": true,
            "notificationTemplate": "Result: {{output}}",
            "barkPushEnabled": true,
            "barkNotifyOnOutputChange": true,
            "pushChannelIDs": ["B820189C-7875-44DE-9A40-479782D1608A"]
        }
        """#.utf8)
        let exported = try JSONDecoder().decode(TaskExporter.ExportedTask.self, from: data)
        let task = TaskExporter.makeTask(from: exported)

        #expect(task.name == "Legacy task")
        #expect(task.scriptBody == "echo hello")
        #expect(task.timeoutSeconds == 120)
        #expect(!task.notifyOnSuccess)
        #expect(task.notifyOnFailure)
        #expect(task.notifyOnlyWhenOutput)
        #expect(task.strongReminder)
        #expect(task.notificationTemplateEnabled)
        #expect(task.notificationTemplate == "Result: {{output}}")

        let reencoded = try JSONEncoder().encode(TaskExporter.makeExported(task))
        let json = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(json["serialNumber"] == nil)
        #expect(json["barkPushEnabled"] == nil)
        #expect(json["barkNotifyOnOutputChange"] == nil)
        #expect(json["pushChannelIDs"] == nil)
    }
}
