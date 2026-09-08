import Foundation
import TaskTickCore

/// Reads the current run's start time from its execution log for the
/// detail-page schedule card.
enum RunningDuration {

    /// `startedAt` of the ExecutionLog currently in `.running` state, or
    /// `nil` if no run is in flight. Picks the most recently started one if
    /// (rarely) more than one are flagged running — that's a defensive
    /// guard for crash-recovered tasks where status didn't get fixed up.
    static func startedAt(for task: ScheduledTask) -> Date? {
        task.executionLogs
            .filter { $0.status == .running && $0.finishedAt == nil }
            .max(by: { $0.startedAt < $1.startedAt })?
            .startedAt
    }

    /// Compact localized duration rendering. Auto-collapses zero leading
    /// components (for example, Simplified Chinese renders a 30-second run as
    /// "30秒" and a 2-minute run as "2分钟5秒"). Always at most two units so
    /// the label stays compact.
    static func format(
        since startedAt: Date,
        now: Date = Date(),
        locale: Locale = appLocale
    ) -> String {
        let elapsed = Int(max(0, now.timeIntervalSince(startedAt)))

        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = [.dropLeading]

        return formatter.string(from: TimeInterval(elapsed)) ?? "0"
    }

    private static var appLocale: Locale {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: saved) ?? .system
        return Locale(identifier: language.resolvedCode)
    }
}
