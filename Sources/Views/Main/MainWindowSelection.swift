import Foundation
import TaskTickCore

/// One-shot rendezvous so CLI and URL handlers can ask the main window
/// to focus a specific task. The main
/// window reads this on appear and on change, then clears it so a later
/// re-appear doesn't re-apply a stale selection.
@MainActor
final class MainWindowSelection: ObservableObject {
    static let shared = MainWindowSelection()
    private init() {}

    @Published var taskToReveal: ScheduledTask?
}

extension Notification.Name {
    /// Posted by CLIBridge for a reveal request. AppDelegate
    /// listens (always alive) and uses `WindowOpener.shared` to bring back
    /// the main window — `Window(id:)` scenes destroy their NSWindow on
    /// close, so AppKit-only lookups can't recreate them.
    static let revealTaskInMain = Notification.Name("TaskTick.revealTaskInMain")
}

/// Bridges `EnvironmentValues.openWindow` (a SwiftUI scene-only API) into
/// non-View contexts like AppDelegate. Stashed by the main window's view on
/// appear, called from the notification observer when the user wants the
/// main window surfaced from elsewhere.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private init() {}

    var openMain: (() -> Void)?
}
