import Combine
import TaskTickCore

/// App-wide selection shared by the main window and menu commands. Keeping the
/// selected model in one observable object lets CommandMenu actions operate on
/// exactly the row the user sees selected, even though commands live outside
/// the main window's view hierarchy.
@MainActor
final class TaskSelectionState: ObservableObject {
    static let shared = TaskSelectionState()
    @Published var selectedTask: ScheduledTask?

    private init() {}
}
