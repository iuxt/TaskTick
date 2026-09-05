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

    /// Compact "Xh Ym Zs" rendering. Auto-collapses zero leading components
    /// (a 30-second run reads "30s", a 2-minute run reads "2m 5s"). Always
    /// at most two units so the label stays compact.
    static func format(since startedAt: Date, now: Date = Date()) -> String {
        let elapsed = Int(max(0, now.timeIntervalSince(startedAt)))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
