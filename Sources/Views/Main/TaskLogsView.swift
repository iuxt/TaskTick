import SwiftUI
import SwiftData
import TaskTickCore

struct TaskLogsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let task: ScheduledTask
    var initialSelectedLogId: UUID?

    @State private var selection: Set<ExecutionLog> = []
    @State private var logsToDelete: [ExecutionLog] = []
    @State private var showingDeleteAlert = false

    var sortedLogs: [ExecutionLog] {
        task.executionLogs.filter { $0.modelContext != nil }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The single log driving the detail pane. Multi-select is for bulk
    /// delete/export; the detail pane keeps showing one entry at a time.
    private var selectedLog: ExecutionLog? {
        guard selection.count == 1, let log = selection.first else { return nil }
        return log.modelContext != nil ? log : nil
    }

    var body: some View {
        Group {
            if sortedLogs.isEmpty {
                emptyView
            } else {
                splitView
            }
        }
        .frame(minWidth: 750, minHeight: 480)
        .alert(L10n.tr("log.delete.title"), isPresented: $showingDeleteAlert) {
            Button(L10n.tr("log.delete.cancel"), role: .cancel) { logsToDelete = [] }
            Button(L10n.tr("log.delete.confirm"), role: .destructive) {
                deleteLogs(logsToDelete)
                logsToDelete = []
            }
        } message: {
            Text(deleteMessage(count: logsToDelete.count))
        }
        .onAppear {
            guard selection.isEmpty else { return }
            let initial = initialSelectedLogId.flatMap { id in
                sortedLogs.first { $0.id == id }
            } ?? sortedLogs.first
            if let initial { selection = [initial] }
        }
    }

    /// Selection filtered down to models still backed by the context, in the
    /// list's display order.
    private var liveSelection: [ExecutionLog] {
        sortedLogs.filter { selection.contains($0) }
    }

    /// macOS convention: right-clicking inside the selection acts on the whole
    /// selection; right-clicking outside it acts on just that row.
    private func deleteTargets(rightClicked log: ExecutionLog) -> [ExecutionLog] {
        let picked = liveSelection
        return picked.contains(log) ? picked : [log]
    }

    private func deleteMenuTitle(count: Int) -> String {
        count > 1 ? L10n.tr("log.delete.menu_many", count) : L10n.tr("log.delete.menu_one")
    }

    private func deleteMessage(count: Int) -> String {
        count > 1 ? L10n.tr("log.delete.message_many", count) : L10n.tr("log.delete.message_one")
    }

    private func deleteLogs(_ targets: [ExecutionLog]) {
        // Resolve the successor before deleting — afterwards `sortedLogs`
        // has already dropped these rows and they're invalidated.
        let successor = LogDeletion.selectionAfterDeleting(targets, from: sortedLogs)
        LogDeletion.delete(targets, in: modelContext)
        selection = successor.map { [$0] } ?? []
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L10n.tr("log.empty.title"),
            systemImage: "tray",
            description: Text(L10n.tr("log.empty.description"))
        )
        .navigationTitle(task.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("log.close")) { dismiss() }
                    .pointerCursor()
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(sortedLogs, selection: $selection) { log in
                HStack(spacing: 8) {
                    StatusBadge(status: log.status, compact: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline)
                        if let ms = log.durationMs {
                            Text(ExecutionLog.formatDuration(ms))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }

                    Spacer()
                }
                .tag(log)
                .padding(.vertical, 2)
                .contextMenu {
                    let targets = deleteTargets(rightClicked: log)
                    Button(deleteMenuTitle(count: targets.count),
                           systemImage: "trash",
                           role: .destructive) {
                        logsToDelete = targets
                        showingDeleteAlert = true
                    }
                }
            }
            .frame(minWidth: 240)
            .navigationTitle(task.name)
            .navigationSubtitle("\(sortedLogs.count) \(L10n.tr("log.count_suffix"))")
            .toolbar {
                // Export sits in the cancellation slot so it renders to the
                // LEFT of Close; Close keeps Esc via an explicit shortcut
                // since it no longer occupies .cancellationAction.
                ToolbarItem(placement: .cancellationAction) {
                    LogExportMenu(
                        title: L10n.tr("log.export"),
                        selectedEnabled: !liveSelection.isEmpty,
                        allEnabled: !sortedLogs.isEmpty,
                        onExportSelected: {
                            let picked = liveSelection
                            if picked.count == 1, let log = picked.first {
                                LogExporter.exportLog(log)
                            } else if !picked.isEmpty {
                                LogExporter.exportLogs(picked, nameHint: task.name)
                            }
                        },
                        onExportAll: {
                            LogExporter.exportLogs(sortedLogs, nameHint: task.name)
                        }
                    )
                    .help(L10n.tr("log.export"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.tr("log.close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .pointerCursor()
                }
            }
        } detail: {
            if let log = selectedLog {
                LogDetailContent(log: log)
            } else {
                ContentUnavailableView(
                    L10n.tr("log.select.title"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.tr("log.select.description"))
                )
            }
        }
    }
}

private struct LogDetailContent: View {
    let log: ExecutionLog
    @ObservedObject private var liveOutput = LiveOutputManager.shared

    private var isLive: Bool {
        guard log.status == .running, let taskId = log.task?.id else { return false }
        return liveOutput.isTracking(taskId)
    }

    private var currentStdout: String? {
        if isLive, let taskId = log.task?.id {
            return liveOutput.stdout(for: taskId)
        }
        return log.stdout
    }

    private var currentStderr: String? {
        if isLive, let taskId = log.task?.id {
            return liveOutput.stderr(for: taskId)
        }
        return log.stderr
    }

    var body: some View {
        // Same layout rule as LogDetailView: metadata takes what it needs,
        // the output pane absorbs the remaining height (issue #42).
        VStack(alignment: .leading, spacing: 0) {
            // Metadata is short and fixed — no scroller, so it can't get
            // greedy and steal height from the output pane below.
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(spacing: 8) {
                        row(L10n.tr("log.detail.trigger"), value: log.triggeredBy.displayName)

                        HStack {
                            Text(L10n.tr("log.detail.status"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if log.status == .running {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            StatusBadge(status: log.status)
                        }

                        if let code = log.exitCode {
                            row(L10n.tr("log.detail.exit_code"), value: "\(code)")
                        }

                        if let ms = log.durationMs {
                            row(L10n.tr("log.detail.duration"), value: ExecutionLog.formatDuration(ms))
                        }

                        if let finished = log.finishedAt {
                            row(L10n.tr("log.detail.finished"), value: finished.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                }

                if log.status == .timeout {
                    TimeoutNoticeView(timeoutSeconds: log.task?.timeoutSeconds)
                }

                if log.status == .failure, SudoTTYFailure.matches(stderr: log.stderr) {
                    SudoNoticeView()
                }
            }
            .padding()

            let combined = [currentStdout, currentStderr]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
            if !combined.isEmpty {
                let isFailure = log.status == .failure || log.status == .timeout
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("log.detail.output"),
                          systemImage: isFailure ? "exclamationmark.triangle" : "text.alignleft")
                        .font(.headline)
                        .foregroundStyle(isFailure ? Color.red : Color.primary)
                    // Always virtualized — completed logs can carry up to
                    // 512KB of stdout from SwiftData and SwiftUI Text
                    // chokes on layout regardless of whether it's live.
                    // No maxHeight: the pane grows with the window.
                    LogTextView(text: combined,
                                font: .monospacedSystemFont(ofSize: 11, weight: .regular))
                        .frame(minHeight: 120, maxHeight: .infinity)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(isFailure ? Color.red.opacity(0.04) : Color.black.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(isFailure ? Color.red.opacity(0.2) : Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
                .padding(.horizontal)
                .padding(.bottom)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}
