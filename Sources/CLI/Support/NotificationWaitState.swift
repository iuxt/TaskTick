import Foundation

/// Owns the resources used while bridging notification callbacks to a
/// continuation. NotificationCenter and Dispatch callbacks are `@Sendable`, so
/// their shared mutable state must be synchronized instead of captured as local
/// variables.
final class NotificationWaitState<Success>: @unchecked Sendable {
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

    /// Completes at most once and tears down every installed callback resource.
    /// The return value lets the winning callback decide whether to print output.
    @discardableResult
    func finish(with result: Result<Success, Error>) -> Bool {
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
        continuation.resume(with: result)
        return true
    }
}
