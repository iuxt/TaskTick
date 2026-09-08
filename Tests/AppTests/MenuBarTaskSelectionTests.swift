import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Menu Bar Task Selection Tests")
struct MenuBarTaskSelectionTests {
    @Test("Background list includes disabled services")
    func includesDisabledBackgroundServices() {
        let enabled = ScheduledTask(name: "enabled")
        enabled.isBackgroundService = true
        enabled.isEnabled = true

        let disabled = ScheduledTask(name: "disabled")
        disabled.isBackgroundService = true
        disabled.isEnabled = false

        let scheduled = ScheduledTask(name: "scheduled")
        scheduled.isBackgroundService = false

        let result = MenuBarTaskSelection.backgroundTasks(
            from: [enabled, disabled, scheduled],
            limit: 5
        )

        #expect(Set(result.map(\.id)) == Set([enabled.id, disabled.id]))
    }
}
