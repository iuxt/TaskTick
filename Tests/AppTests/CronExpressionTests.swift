import Foundation
import Testing
@testable import TaskTickApp
import TaskTickCore

@Suite("CronExpression Tests")
struct CronExpressionTests {

    @Test("Parse every minute")
    func parseEveryMinute() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        #expect(cron.minute == .any)
        #expect(cron.hour == .any)
        #expect(cron.dayOfMonth == .any)
        #expect(cron.month == .any)
        #expect(cron.dayOfWeek == .any)
    }

    @Test("Parse step expression")
    func parseStep() throws {
        let cron = try CronExpression(parsing: "*/5 * * * *")
        #expect(cron.minute == .step(5))
    }

    @Test("Parse specific value")
    func parseValue() throws {
        let cron = try CronExpression(parsing: "30 8 * * *")
        #expect(cron.minute == .value(30))
        #expect(cron.hour == .value(8))
    }

    @Test("Parse range")
    func parseRange() throws {
        let cron = try CronExpression(parsing: "0 9-17 * * *")
        #expect(cron.hour == .range(9, 17))
    }

    @Test("Reversed ranges are rejected instead of creating inert schedules")
    func reversedRangeThrows() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "0 17-9 * * *")
        }
    }

    @Test("Range steps, month names and Sunday 7 use crontab semantics")
    func commonCrontabSyntax() throws {
        let stepped = try CronExpression(parsing: "1-10/2 * * * *")
        #expect(stepped.minute == .rangeStep(1, 10, 2))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let saturday = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 3, hour: 23, minute: 59
        ))!
        let named = try CronExpression(parsing: "0 0 * JAN SUN")
        let sundaySeven = try CronExpression(parsing: "0 0 * JAN 7")
        let expected = calendar.date(from: DateComponents(year: 2026, month: 1, day: 4))
        #expect(named.nextFireDate(after: saturday, calendar: calendar) == expected)
        #expect(sundaySeven.nextFireDate(after: saturday, calendar: calendar) == expected)
    }

    @Test("Invalid format throws")
    func invalidFormat() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "* * *")
        }
    }

    @Test("Value out of range throws")
    func valueOutOfRange() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "60 * * * *")
        }
    }

    @Test("Next fire date calculation")
    func nextFireDate() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        let next = cron.nextFireDate()
        #expect(next != nil)
    }

    @Test("Impossible calendar dates return quickly")
    func impossibleDateIsBounded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDate = calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 1, hour: 0, minute: 0
        ))!
        let cron = try CronExpression(parsing: "0 0 31 2 *")
        let clock = ContinuousClock()
        let started = clock.now

        #expect(cron.nextFireDate(after: startDate, calendar: calendar) == nil)
        #expect(started.duration(to: clock.now) < .milliseconds(250))
    }

    @Test("Restricted day-of-month and weekday use crontab OR semantics")
    func dayFieldsUseOrSemantics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 1, hour: 0, minute: 0
        ))!
        let cron = try CronExpression(parsing: "0 0 1 * 1")

        // September 7 is a Monday and must match even though it is not day 1.
        let next = cron.nextFireDate(after: start, calendar: calendar)
        #expect(next == calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 0, minute: 0
        )))
    }

    @Test("Steps in one-based fields start at the field minimum")
    func oneBasedStepsUseFieldMinimum() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 1, hour: 0, minute: 0
        ))!

        let dayStep = try CronExpression(parsing: "0 0 */2 * *")
        #expect(dayStep.nextFireDate(after: start, calendar: calendar) == calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 3, hour: 0, minute: 0)
        ))

        let monthStep = try CronExpression(parsing: "0 0 1 */2 *")
        #expect(monthStep.nextFireDate(after: start, calendar: calendar) == calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 0)
        ))
    }

    @Test("Human readable presets")
    func humanReadable() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        #expect(cron.humanReadable == "每分钟")

        let hourly = try CronExpression(parsing: "0 * * * *")
        #expect(hourly.humanReadable == "每小时")
    }
}
