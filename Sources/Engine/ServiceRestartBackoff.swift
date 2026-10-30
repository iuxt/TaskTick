import Foundation

/// Consecutive short-lived runs double the configured initial delay. A stable
/// run or an explicit Stop/start begins a fresh sequence.
struct ServiceRestartBackoff {
    static let stableRunDuration: TimeInterval = 60
    static let maximumDelay: TimeInterval = 300

    private var previousDelay: TimeInterval?

    mutating func nextDelay(initialDelay: Int, runDuration: TimeInterval) -> TimeInterval {
        let initial = TimeInterval(max(1, initialDelay))
        // Never shorten a deliberately configured delay longer than the cap.
        let maximum = max(initial, Self.maximumDelay)
        if runDuration >= Self.stableRunDuration {
            previousDelay = nil
        }
        let delay = min(max(initial, previousDelay.map { $0 * 2 } ?? initial), maximum)
        previousDelay = delay
        return delay
    }
}
