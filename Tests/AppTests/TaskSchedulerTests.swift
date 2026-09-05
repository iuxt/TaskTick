import Testing
import Foundation
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("TaskScheduler Tests")
struct TaskSchedulerTests {

    @Test("Scheduler singleton exists")
    @MainActor
    func schedulerExists() {
        let scheduler = TaskScheduler.shared
        #expect(scheduler.isRunning == false)
    }

    // Regression for issue #30: a fresh task with no scheduledDate but a
    // sub-day repeat (every minute) used to land in the legacy interval
    // branch and return nil, blocking the scheduler from picking it up.
    @Test("Every-minute task without scheduledDate computes future nextRunAt")
    @MainActor
    func everyMinuteWithoutScheduledDateComputesNextRun() {
        let task = ScheduledTask(
            name: "issue-30",
            scriptBody: "echo hi",
            scheduledDate: nil,
            repeatType: .everyMinute
        )
        task.intervalSeconds = nil
        task.cronExpression = nil

        let anchor = Date()
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: anchor)

        #expect(next != nil)
        if let next {
            let delta = next.timeIntervalSince(anchor)
            #expect(delta > 0)
            #expect(delta <= 60)
        }
    }

    @Test("Legacy interval task still honors intervalSeconds")
    @MainActor
    func legacyIntervalTaskStillWorks() {
        let task = ScheduledTask(name: "legacy", scriptBody: "echo hi")
        task.scheduledDate = nil
        task.intervalSeconds = 300
        task.cronExpression = nil

        let anchor = Date()
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: anchor)

        #expect(next != nil)
        if let next {
            #expect(abs(next.timeIntervalSince(anchor) - 300) < 1)
        }
    }

    // Issue #34: a daily task with extra time points should fire at the earliest
    // upcoming time of day, then walk forward through main + extras.
    @Test("Daily task with additional times picks the earliest upcoming slot")
    @MainActor
    func dailyAdditionalTimesPicksEarliest() {
        let cal = Calendar.current
        // Anchor "now" at today 10:00 so the slots straddle it.
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 10
        comps.minute = 0
        comps.second = 0
        let now = cal.date(from: comps) ?? Date()

        // Main fire at 09:00 (already passed today), extras at 12:00 and 18:00.
        var mainComps = comps
        mainComps.hour = 9
        let mainDate = cal.date(from: mainComps) ?? now

        let task = ScheduledTask(
            name: "issue-34",
            scriptBody: "echo hi",
            scheduledDate: mainDate,
            repeatType: .daily
        )
        task.additionalTimes = [
            DateComponents(hour: 12, minute: 0),
            DateComponents(hour: 18, minute: 0)
        ]

        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next != nil)
        if let next {
            let h = cal.component(.hour, from: next)
            let m = cal.component(.minute, from: next)
            #expect(h == 12)
            #expect(m == 0)
        }
    }

    // After consuming all of today's slots the scheduler should roll to
    // tomorrow's earliest configured time, not silently return nil.
    @Test("Additional times roll to the next day after the last slot")
    @MainActor
    func additionalTimesRollOverToNextDay() {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 20
        comps.minute = 0
        comps.second = 0
        let now = cal.date(from: comps) ?? Date()

        var mainComps = comps
        mainComps.hour = 9
        let mainDate = cal.date(from: mainComps) ?? now

        let task = ScheduledTask(
            name: "issue-34-rollover",
            scriptBody: "echo hi",
            scheduledDate: mainDate,
            repeatType: .daily
        )
        task.additionalTimes = [
            DateComponents(hour: 12, minute: 0),
            DateComponents(hour: 18, minute: 0)
        ]

        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next != nil)
        if let next {
            // Tomorrow @ 09:00
            let delta = next.timeIntervalSince(now)
            #expect(delta > 12 * 3600)  // > 12h away
            #expect(delta < 16 * 3600)  // < 16h away (09:00 is 13h after 20:00)
            #expect(cal.component(.hour, from: next) == 9)
        }
    }

    @Test("Old multi-time schedules fast-forward to the current day")
    @MainActor
    func oldAdditionalTimesStillSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let scheduled = calendar.date(from: DateComponents(
            year: 2023, month: 1, day: 1, hour: 9
        ))!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 10
        ))!
        let task = ScheduledTask(
            name: "old multi-time", scheduledDate: scheduled, repeatType: .daily
        )
        task.timeZoneIdentifier = "UTC"
        task.additionalTimes = [DateComponents(hour: 18, minute: 0)]

        #expect(TaskScheduler.shared.computeNextRunDate(for: task, after: now) == calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 5, hour: 18)
        ))
    }

    @Test("Cron schedule does not cross its end date")
    @MainActor
    func cronHonorsEndDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 10
        ))!
        let task = ScheduledTask(name: "ending cron")
        task.schedule = .cron
        task.cronExpression = "0 9 * * *"
        task.timeZoneIdentifier = "UTC"
        task.endRepeatType = .onDate
        task.endRepeatDate = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 5, hour: 12
        ))!

        #expect(TaskScheduler.shared.computeNextRunDate(for: task, after: now) == nil)
    }

    // Roundtrip: encoding then decoding `additionalTimes` should survive.
    @Test("additionalTimes serializes and deserializes via JSON")
    @MainActor
    func additionalTimesRoundtrip() {
        let task = ScheduledTask(name: "roundtrip", scriptBody: "echo hi")
        task.additionalTimes = [
            DateComponents(hour: 9, minute: 30),
            DateComponents(hour: 18, minute: 0)
        ]
        // Force a re-read through the accessor (decodes from stored JSON).
        let decoded = task.additionalTimes
        #expect(decoded.count == 2)
        #expect(decoded[0].hour == 9 && decoded[0].minute == 30)
        #expect(decoded[1].hour == 18 && decoded[1].minute == 0)
    }
}
