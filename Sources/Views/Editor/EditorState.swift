import Foundation
import TaskTickCore

enum TaskCreationKind {
    case scheduled
    case background
}

/// Shared state for the task editor window.
@MainActor
final class EditorState: ObservableObject {
    static let shared = EditorState()

    @Published var taskToEdit: ScheduledTask?
    @Published var isPresented = false
    @Published var lastSavedTask: ScheduledTask?
    @Published var pendingTemplate: ScriptTemplate?
    /// Determines the tailored defaults and tabs used when creating a task.
    @Published var creationKind: TaskCreationKind = .scheduled
    /// Incremented on every open call to force TaskEditorView to reload.
    @Published var openTrigger = 0

    private init() {}

    func openNew(kind: TaskCreationKind = .scheduled) {
        taskToEdit = nil
        pendingTemplate = nil
        creationKind = kind
        openTrigger += 1
        isPresented = true
    }

    func openNewFromTemplate(_ template: ScriptTemplate) {
        taskToEdit = nil
        pendingTemplate = template
        creationKind = .scheduled
        openTrigger += 1
        isPresented = true
    }

    func openEdit(_ task: ScheduledTask) {
        taskToEdit = task
        pendingTemplate = nil
        creationKind = task.isBackgroundService ? .background : .scheduled
        openTrigger += 1
        isPresented = true
    }

    func close() {
        isPresented = false
        taskToEdit = nil
        pendingTemplate = nil
    }
}
