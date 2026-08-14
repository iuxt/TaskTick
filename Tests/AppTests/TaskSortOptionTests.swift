import Testing
import Foundation
import TaskTickCore
@testable import TaskTickApp

@Suite("TaskSortOption Tests")
struct TaskSortOptionTests {

    private func task(_ name: String, created: TimeInterval, lastRun: TimeInterval?) -> ScheduledTask {
        let t = ScheduledTask(name: name)
        t.createdAt = Date(timeIntervalSince1970: created)
        t.lastRunAt = lastRun.map { Date(timeIntervalSince1970: $0) }
        return t
    }

    @Test("createdDesc orders newest-created first")
    func createdDesc() {
        let a = task("a", created: 100, lastRun: nil)
        let b = task("b", created: 200, lastRun: nil)
        #expect(TaskSortOption.createdDesc.sort([a, b]).map(\.name) == ["b", "a"])
    }

    @Test("createdAsc orders oldest-created first")
    func createdAsc() {
        let a = task("a", created: 100, lastRun: nil)
        let b = task("b", created: 200, lastRun: nil)
        #expect(TaskSortOption.createdAsc.sort([b, a]).map(\.name) == ["a", "b"])
    }

    @Test("lastRunDesc orders most-recently-run first, falling back to createdAt")
    func lastRunDesc() {
        let a = task("a", created: 100, lastRun: 500) // ran at 500
        let b = task("b", created: 300, lastRun: nil) // never ran → createdAt 300
        #expect(TaskSortOption.lastRunDesc.sort([b, a]).map(\.name) == ["a", "b"])
    }

    @Test("lastRunAsc orders least-recently-run first")
    func lastRunAsc() {
        let a = task("a", created: 100, lastRun: 500)
        let b = task("b", created: 300, lastRun: nil)
        #expect(TaskSortOption.lastRunAsc.sort([a, b]).map(\.name) == ["b", "a"])
    }

    @Test("disabled tasks sink below enabled ones, whatever the time ordering")
    func disabledSinks() {
        let enabled = task("enabled", created: 100, lastRun: nil)   // oldest
        let disabled = task("disabled", created: 900, lastRun: nil) // newest
        disabled.isEnabled = false
        // createdDesc would normally put the newer "disabled" first.
        #expect(TaskSortOption.createdDesc.sort([disabled, enabled]).map(\.name) == ["enabled", "disabled"])
        // ...and createdAsc would normally put the older "enabled" first anyway,
        // so check the option that would otherwise disagree too.
        #expect(TaskSortOption.createdAsc.sort([disabled, enabled]).map(\.name) == ["enabled", "disabled"])
    }

    @Test("disabled tasks keep the time ordering among themselves")
    func disabledOrderedInternally() {
        let old = task("old", created: 100, lastRun: nil)
        let new = task("new", created: 900, lastRun: nil)
        old.isEnabled = false
        new.isEnabled = false
        #expect(TaskSortOption.createdDesc.sort([old, new]).map(\.name) == ["new", "old"])
        #expect(TaskSortOption.createdAsc.sort([new, old]).map(\.name) == ["old", "new"])
    }
}
