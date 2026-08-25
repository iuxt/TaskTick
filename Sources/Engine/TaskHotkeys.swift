import AppKit
import Foundation
import KeyboardShortcuts
import SwiftData
import TaskTickCore

/// Naming scheme for per-task global shortcuts (issue #49).
///
/// The shortcut itself lives in KeyboardShortcuts' own `UserDefaults` storage
/// rather than in SwiftData. One source of truth on purpose: the library's
/// Recorder reads and writes that storage directly, so mirroring the value into
/// the model would give us two places to disagree — the exact "UI says A, disk
/// says B" split that keeps biting elsewhere.
enum TaskHotkeys {

    /// Prefix shared by every per-task name, so orphans left behind by deleted
    /// tasks can be found again.
    static let prefix = "task-"

    static func name(for taskID: UUID) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("\(prefix)\(taskID.uuidString)")
    }

    /// Scratch binding the editor records into.
    ///
    /// The editor has Cancel, but the Recorder writes through on every
    /// keystroke — recording straight into the task's real name would make
    /// "Cancel" a lie. The editor stages here and commits on Save. It also
    /// gives a brand-new (not yet persisted) task somewhere to record into.
    /// `Name` isn't Sendable, so this is main-actor bound rather than a plain
    /// global. Every caller (the editor window, the manager) is already there.
    @MainActor static let draft = KeyboardShortcuts.Name("\(prefix)draft")

    static func taskID(fromDefaultsKey key: String) -> UUID? {
        let fullPrefix = "KeyboardShortcuts_\(prefix)"
        guard key.hasPrefix(fullPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(fullPrefix.count)))
    }
}

/// Wires per-task shortcuts up to the run action and keeps the stored set tidy.
///
/// Handlers are registered exactly once per task for the lifetime of the
/// process. That's not an optimization — `KeyboardShortcuts.onKeyDown` *appends*
/// to a list and the library exposes no way to remove a single handler, so
/// re-registering on every task edit would make one keypress launch the task
/// twice, then three times. Clearing a task's shortcut is what stops it firing.
@MainActor
final class TaskHotkeyManager: ObservableObject {

    static let shared = TaskHotkeyManager()

    private var modelContainer: ModelContainer?
    private var handlerRegistered: Set<UUID> = []

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        // A draft left over from an editor window that died with the app would
        // otherwise keep its chord claimed system-wide with nothing behind it.
        discardDraft()
        discardOrphanedShortcuts()
        syncHandlers()
        // Both steps above clear shortcuts by value and can collateral-damage a
        // live binding that happens to share a chord. Last word goes to re-arm.
        rearmAll()
    }

    /// Release a task's binding (it's being deleted). Same value-keyed pitfall:
    /// clearing this one can unregister a sibling task holding the same chord,
    /// so everything gets re-armed afterwards.
    func discardShortcut(for taskID: UUID) {
        KeyboardShortcuts.setShortcut(nil, for: TaskHotkeys.name(for: taskID))
        rearmAll()
    }

    /// Drop the editor's staged shortcut and re-arm everything else.
    ///
    /// KeyboardShortcuts keeps its registration ledger keyed by *shortcut
    /// value*, not by name, and clearing a name unregisters that value
    /// unconditionally — it never checks whether another name still holds it.
    /// The draft holds the very same chord as the task it was staged from (on
    /// every load, and on every save), so dropping it tears the task's live
    /// registration down too. The stored value survives, which is why the UI
    /// still shows the shortcut while nothing happens when you press it.
    /// Re-arming is what keeps the binding real.
    func discardDraft() {
        TaskHotkeys.draft.shortcut = nil
        rearmAll()
    }

    /// Re-register every task binding. Idempotent and cheap — the library skips
    /// any shortcut value it already has registered.
    func rearmAll() {
        KeyboardShortcuts.enable(allTasks().map { TaskHotkeys.name(for: $0.id) })
    }

    /// Register run-handlers for any task that doesn't have one yet.
    func syncHandlers() {
        for task in allTasks() where !handlerRegistered.contains(task.id) {
            let taskID = task.id
            handlerRegistered.insert(taskID)
            KeyboardShortcuts.onKeyDown(for: TaskHotkeys.name(for: taskID)) {
                MainActor.assumeIsolated {
                    TaskHotkeyManager.shared.trigger(taskID: taskID)
                }
            }
        }
    }

    /// Drop shortcuts whose task no longer exists. Deletion paths clear their
    /// own binding; this is the backstop for anything that got away (a task
    /// removed while the app was down, a restore from an older backup).
    private func discardOrphanedShortcuts() {
        let liveIDs = Set(allTasks().map(\.id))
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            guard let taskID = TaskHotkeys.taskID(fromDefaultsKey: key),
                  !liveIDs.contains(taskID) else { continue }
            KeyboardShortcuts.setShortcut(nil, for: TaskHotkeys.name(for: taskID))
        }
    }

    /// Name of whatever already owns `shortcut`, or nil when it's free. The
    /// library warns about system and main-menu collisions on its own; this
    /// covers the two it can't see — our own Quick Launcher and sibling tasks.
    func conflictOwner(for shortcut: KeyboardShortcuts.Shortcut, excluding taskID: UUID?) -> String? {
        if shortcut == quickLauncherShortcut() {
            return L10n.tr("quick_launcher.menu_item")
        }
        for task in allTasks() where task.id != taskID {
            if TaskHotkeys.name(for: task.id).shortcut == shortcut {
                return task.name
            }
        }
        return nil
    }

    /// Run the task behind a shortcut press. Feedback is forced on: a global
    /// shortcut fires with no window in sight, so without a banner there's no
    /// way to tell a working binding from a broken one.
    ///
    /// A disabled task stays silent — it's hidden from the menu bar and the
    /// Quick Launcher too, and the editor promises as much.
    private func trigger(taskID: UUID) {
        guard let task = allTasks().first(where: { $0.id == taskID }) else { return }
        guard task.isEnabled else { return }
        CLIBridge.shared.handle(action: .run, taskId: taskID, forceBanner: true)
    }

    private func quickLauncherShortcut() -> KeyboardShortcuts.Shortcut? {
        let settings = QuickLauncherSettings.shared
        guard settings.isEnabled else { return nil }
        return KeyboardShortcuts.Shortcut(
            KeyboardShortcuts.Key(rawValue: settings.keyCode),
            modifiers: settings.modifiers
        )
    }

    private func allTasks() -> [ScheduledTask] {
        guard let modelContainer else { return [] }
        return (try? modelContainer.mainContext.fetch(FetchDescriptor<ScheduledTask>())) ?? []
    }
}
