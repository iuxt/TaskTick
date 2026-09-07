import SwiftUI
import SwiftData
import TaskTickCore

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editorState = EditorState.shared
    @State private var selectedTask: ScheduledTask?
    @State private var taskKindFilter: TaskKindFilter = .all
    @AppStorage("taskSortOption") private var sortOptionRaw = TaskSortOption.lastRunDesc.rawValue
    @Binding var showingCrontabImport: Bool

    var body: some View {
        NavigationSplitView {
            TaskListView(
                selectedTask: $selectedTask,
                sortOptionRaw: $sortOptionRaw,
                kindFilter: $taskKindFilter
            )
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                // Keep the sidebar toolbar down to a single item. macOS 26 sizes
                // toolbar overflow against the *column* width, so a second item
                // pushed "+" into the "»" overflow menu at narrow sidebar widths
                // (issue #46). Sorting now lives in the filter bar instead.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                taskKindFilter = .all
                                EditorState.shared.openNew(kind: .scheduled)
                                openWindow(id: "editor")
                            } label: {
                                Label(L10n.tr("task.mode.scheduled"), systemImage: "calendar.badge.clock")
                            }

                            Button {
                                taskKindFilter = .all
                                EditorState.shared.openNew(kind: .background)
                                openWindow(id: "editor")
                            } label: {
                                Label(L10n.tr("task.mode.background"), systemImage: "terminal.fill")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("command.new_task"))
                    }
                }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("task.select.title"), systemImage: "checklist")
                } description: {
                    Text(L10n.tr("task.select.description"))
                }
            }
        }
        .sheet(isPresented: $showingCrontabImport) {
            CrontabImportView()
        }
        .onChange(of: editorState.lastSavedTask) { _, newTask in
            if let task = newTask {
                taskKindFilter = .all
                selectedTask = task
                editorState.lastSavedTask = nil
            }
        }
        .onAppear {
            // Capture `openWindow` so AppDelegate / other non-View contexts
            // can reopen the main window after it's been closed (Window(id:)
            // destroys the NSWindow on close — only SwiftUI's openWindow
            // can resurrect it).
            WindowOpener.shared.openMain = { openWindow(id: "main") }
        }
    }
}
