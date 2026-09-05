import XCTest
import SwiftData
import TaskTickCore
@testable import tasktick

@MainActor
final class ReadOnlyStoreTests: XCTestCase {

    func testOpensExistingStoreAndFetchesTasks() throws {
        // Set up a temp store with one task.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-cli-test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let schema = Schema([ScheduledTask.self, ExecutionLog.self])
            let cfg = ModelConfiguration(schema: schema, url: tmp, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [cfg])
            let ctx = container.mainContext
            ctx.insert(ScheduledTask(name: "Test Task"))
            try ctx.save()
        }

        // Open it read-only via ReadOnlyStore.
        let store = try ReadOnlyStore(url: tmp)
        let tasks = try store.fetchTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.name, "Test Task")
    }

    func testOpensEmptyStoreWithoutCrashing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-cli-empty-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try ReadOnlyStore(url: tmp)
        let tasks = try store.fetchTasks()
        XCTAssertEqual(tasks.count, 0)
    }

    func testFetchRunningLogIncludesFirstExecution() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-cli-running-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let taskID: UUID

        do {
            let schema = Schema([ScheduledTask.self, ExecutionLog.self])
            let cfg = ModelConfiguration(schema: schema, url: tmp, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [cfg])
            let context = container.mainContext
            let task = ScheduledTask(name: "First run")
            taskID = task.id
            context.insert(task)
            context.insert(ExecutionLog(task: task))
            try context.save()
        }

        let store = try ReadOnlyStore(url: tmp)
        XCTAssertNotNil(try store.fetchRunningLog(forTaskId: taskID))
        XCTAssertNil(try store.fetchLatestLog(forTaskId: taskID))
    }
}
