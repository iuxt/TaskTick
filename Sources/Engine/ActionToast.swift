import Foundation
import TaskTickCore

/// Single entry point for "user just performed an action" banners.
/// Run/Stop actions can display a native notification.
enum ActionToast {

    enum Event {
        case started(taskName: String)
        case stopped(taskName: String)
    }

    /// Whether an action-feedback banner should fire. Requires the global
    /// `notificationsEnabled` switch (default on) AND the per-task opt-in
    /// `wantsBanner` (the task's `notifyOnAction`, default OFF).
    static func isEnabled(wantsBanner: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        let global = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        return global && wantsBanner
    }

    /// Fire an action-feedback banner when the task and global settings enable it.
    static func notify(_ event: Event, wantsBanner: Bool) {
        guard isEnabled(wantsBanner: wantsBanner) else { return }
        let (title, body) = previewContent(for: event)
        NotificationManager.shared.sendNotification(title: title, body: body)
    }

    /// Pure helper used by tests — renders the strings without sending.
    static func previewContent(for event: Event) -> (title: String, body: String) {
        switch event {
        case .started(let name):
            return (L10n.tr("toast.action.started"), name)
        case .stopped(let name):
            return (L10n.tr("toast.action.stopped"), name)
        }
    }
}
