import Testing
import Foundation
import SwiftData
import TaskTickCore
@testable import TaskTickApp

/// Covers the post-delete selection rule for the log lists: land on the next
/// surviving row below the deleted block, falling back to the nearest one
/// above when the block ran to the end of the list.
@Suite("Log deletion selection")
@MainActor
struct LogDeletionTests {

    /// Builds `count` logs held by an in-memory container, ordered as the
    /// lists display them. They must stay context-backed for the whole test —
    /// the helper compares live model identities.
    private func makeLogs(_ count: Int) throws -> (container: ModelContainer, logs: [ExecutionLog]) {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let cfg = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let ctx = container.mainContext

        let logs = (0..<count).map { _ -> ExecutionLog in
            let log = ExecutionLog()
            ctx.insert(log)
            return log
        }
        return (container, logs)
    }

    @Test("删中间一条 → 选中下一条")
    func deleteMiddleSelectsNext() throws {
        let (container, logs) = try makeLogs(5)
        _ = container

        let next = LogDeletion.selectionAfterDeleting([logs[1]], from: logs)
        #expect(next === logs[2])
    }

    @Test("删最后一条 → 回退选上一条")
    func deleteLastFallsBackToPrevious() throws {
        let (container, logs) = try makeLogs(5)
        _ = container

        let next = LogDeletion.selectionAfterDeleting([logs[4]], from: logs)
        #expect(next === logs[3])
    }

    @Test("删第一条 → 选中下一条")
    func deleteFirstSelectsNext() throws {
        let (container, logs) = try makeLogs(3)
        _ = container

        let next = LogDeletion.selectionAfterDeleting([logs[0]], from: logs)
        #expect(next === logs[1])
    }

    @Test("多选删除末尾一段 → 回退到该段之前的存活行")
    func deleteTrailingBlockFallsBack() throws {
        let (container, logs) = try makeLogs(5)
        _ = container

        let next = LogDeletion.selectionAfterDeleting([logs[3], logs[4]], from: logs)
        #expect(next === logs[2])
    }

    @Test("多选不连续 → 跳过被删项选下一个存活行")
    func discontiguousSelectionSkipsDeleted() throws {
        let (container, logs) = try makeLogs(5)
        _ = container

        // Remove rows 1 and 2; the first survivor below index 1 is row 3.
        let next = LogDeletion.selectionAfterDeleting([logs[1], logs[2]], from: logs)
        #expect(next === logs[3])
    }

    @Test("删光所有行 → 无可选项")
    func deleteEverythingClearsSelection() throws {
        let (container, logs) = try makeLogs(3)
        _ = container

        let next = LogDeletion.selectionAfterDeleting(logs, from: logs)
        #expect(next == nil)
    }

    @Test("仅一行且被删 → 无可选项")
    func deleteOnlyRowClearsSelection() throws {
        let (container, logs) = try makeLogs(1)
        _ = container

        let next = LogDeletion.selectionAfterDeleting([logs[0]], from: logs)
        #expect(next == nil)
    }

    @Test("删除项不在可见列表中（已被筛选掉）→ 不改动选中")
    func deletingInvisibleRowReturnsNil() throws {
        let (container, logs) = try makeLogs(4)
        _ = container

        // Simulates deleting via a filter that hides the target row.
        let visible = Array(logs[0..<3])
        let next = LogDeletion.selectionAfterDeleting([logs[3]], from: visible)
        #expect(next == nil)
    }
}
