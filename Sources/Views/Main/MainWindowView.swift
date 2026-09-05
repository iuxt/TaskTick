import SwiftUI
import SwiftData
import TaskTickCore

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editorState = EditorState.shared
    @StateObject private var mainSelection = MainWindowSelection.shared
    @State private var selectedTask: ScheduledTask?
    @State private var selectedTab: TaskListTab = .scheduled
    @AppStorage("taskSortOption") private var sortOptionRaw = TaskSortOption.lastRunDesc.rawValue
    @Binding var showingCrontabImport: Bool

    var body: some View {
        NavigationSplitView {
            TaskListView(
                selectedTask: $selectedTask,
                sortOptionRaw: $sortOptionRaw,
                selectedTab: $selectedTab
            )
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                // Keep the sidebar toolbar down to a single item. macOS 26 sizes
                // toolbar overflow against the *column* width, so a second item
                // pushed "+" into the "»" overflow menu at narrow sidebar widths
                // (issue #46). Sorting now lives in the filter bar instead.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            EditorState.shared.openNew(kind: selectedTab.creationKind)
                            openWindow(id: "editor")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(selectedTab == .background
                              ? L10n.tr("task.mode.background")
                              : L10n.tr("command.new_task"))
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
                selectedTab = task.isBackgroundService ? .background : .scheduled
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

            // When a reveal request opens the main window, the window
            // scene may instantiate fresh — pick up the rendezvous selection
            // here so the first render already shows the requested task.
            if let task = mainSelection.taskToReveal {
                selectedTab = task.isBackgroundService ? .background : .scheduled
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
        .onChange(of: mainSelection.taskToReveal) { _, newTask in
            if let task = newTask {
                selectedTab = task.isBackgroundService ? .background : .scheduled
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
    }
}
