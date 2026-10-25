import Foundation
import TaskTickCore

/// The editor's schedule is applied identically when previewing and saving.
struct TaskScheduleConfiguration {
    var isManualOnly = false
    var hasDate = true
    var hasTime = true
    var scheduledDate = Date()
    var repeatType: RepeatType = .daily
    var customIntervalValue = 1
    var customIntervalUnit: CustomRepeatUnit = .day
    var useCron = false
    var cronExpression = ""
    var additionalTimes: [DateComponents] = []
    var endRepeatType: EndRepeatType = .never
    var endRepeatDate: Date?
    var endRepeatCount: Int?
    var jitterSeconds = 0
    var timeZoneID: String?
    var runMissedExecution = false
    var runOnLaunch = false

    func apply(to task: ScheduledTask) {
        task.isManualOnly = isManualOnly
        task.hasDate = !useCron && hasDate
        task.hasTime = !useCron && hasTime
        task.scheduledDate = !useCron && (hasDate || hasTime) ? scheduledDate : nil
        task.repeatType = repeatType
        task.customIntervalValue = customIntervalValue
        task.customIntervalUnit = customIntervalUnit
        task.schedule = useCron ? .cron : .interval
        task.cronExpression = useCron ? cronExpression.trimmingCharacters(in: .whitespaces) : nil
        task.intervalSeconds = nil
        task.timeZoneIdentifier = timeZoneID
        task.scheduleAnchorTimeZoneIdentifier = task.scheduleCalendar.timeZone.identifier
        task.jitterSeconds = max(0, jitterSeconds)
        task.endRepeatType = useCron || repeatType != .never ? endRepeatType : .never
        task.endRepeatDate = endRepeatType == .onDate ? endRepeatDate : nil
        task.endRepeatCount = endRepeatType == .afterCount ? endRepeatCount : nil
        task.runMissedExecution = runMissedExecution
        task.runOnLaunch = !isManualOnly && runOnLaunch

        // Preserve extra times across repeat-type changes, excluding duplicate
        // slots and the main time. The scheduler decides which types use them.
        if !useCron && hasTime {
            let main = task.scheduleCalendar.dateComponents([.hour, .minute], from: scheduledDate)
            var seen = Set<Int>()
            if let hour = main.hour, let minute = main.minute { seen.insert(hour * 60 + minute) }
            task.additionalTimes = additionalTimes.filter {
                guard let hour = $0.hour, let minute = $0.minute else { return false }
                return seen.insert(hour * 60 + minute).inserted
            }
        } else {
            task.additionalTimes = []
        }
    }

    @MainActor
    func nextRun(after date: Date = Date(), taskID: UUID, executionCount: Int) -> Date? {
        let preview = ScheduledTask()
        preview.id = taskID
        preview.executionCount = executionCount
        apply(to: preview)
        return TaskScheduler.shared.computeNextRunDate(for: preview, after: date)
    }
}
