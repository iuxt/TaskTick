import Foundation

/// Owns the resources used while bridging notification callbacks to a
/// continuation. NotificationCenter and Dispatch callbacks are `@Sendable`, so
/// their shared mutable state must be synchronized instead of captured as local
/// variables.
final class NotificationWaitState<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let center: DistributedNotificationCenter
    private let continuation: CheckedContinuation<Success, Error>

    private var observers: [NSObjectProtocol] = []
    private var signalSource: DispatchSourceSignal?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isFinished = false

    init(
        center: DistributedNotificationCenter,
        continuation: CheckedContinuation<Success, Error>
    ) {
        self.center = center
        self.continuation = continuation
    }

    func installObserver(_ observer: NSObjectProtocol) {
        lock.lock()
        if isFinished {
            lock.unlock()
            center.removeObserver(observer)
        } else {
            observers.append(observer)
            lock.unlock()
        }
    }

    func installSignalSource(_ source: DispatchSourceSignal) {
        lock.lock()
        if isFinished {
            lock.unlock()
            source.cancel()
        } else {
            signalSource = source
            lock.unlock()
        }
    }

    func installTimeoutWorkItem(_ workItem: DispatchWorkItem) {
        lock.lock()
        if isFinished {
            lock.unlock()
            workItem.cancel()
        } else {
            timeoutWorkItem = workItem
            lock.unlock()
        }
    }

    /// Resumes successfully at most once. `sending` transfers the value into
    /// the suspended task instead of retaining a task-isolated value here.
    @discardableResult
    func succeed(with value: sending Success) -> Bool {
        guard beginFinishing() else { return false }
        continuation.resume(returning: value)
        return true
    }

    /// Resumes with an error at most once.
    @discardableResult
    func fail(with error: sending Error) -> Bool {
        guard beginFinishing() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    /// Claims completion and tears down every installed callback resource.
    private func beginFinishing() -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }

        isFinished = true
        let observersToRemove = observers
        let signalSourceToCancel = signalSource
        let timeoutWorkItemToCancel = timeoutWorkItem
        observers.removeAll()
        signalSource = nil
        timeoutWorkItem = nil
        lock.unlock()

        for observer in observersToRemove {
            center.removeObserver(observer)
        }
        signalSourceToCancel?.cancel()
        timeoutWorkItemToCancel?.cancel()
        return true
    }
}
