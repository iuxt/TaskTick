import Foundation
import TaskTickCore

/// One execution's stop reason, shared by the UI and its process worker.
/// First reason wins, so Stop cannot relabel an already-expired deadline.
final class ExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: ExecutionStatus?

    var stopReason: ExecutionStatus? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    func requestStop(_ status: ExecutionStatus) {
        lock.lock(); defer { lock.unlock() }
        if reason == nil { reason = status }
    }
}
