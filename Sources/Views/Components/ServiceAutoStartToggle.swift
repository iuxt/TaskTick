import SwiftUI
import SwiftData
import TaskTickCore

struct ServiceAutoStartToggle: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared
    let task: ScheduledTask

    var body: some View {
        Toggle(L10n.tr("service.auto_start"), isOn: Binding(
            get: { task.isEnabled && task.serviceAutoStart && launchAtLogin.isEnabled },
            set: { enabled in
                setServiceAutoStart(enabled, task: task, context: modelContext)
            }
        ))
        .toggleStyle(.switch)
        .fixedSize()
        .help(L10n.tr("service.auto_start.help"))
        .pointerCursor()
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}
