import SwiftUI
import TaskTickCore

/// Observe streaming updates here so each flush only redraws the log card.
struct ServiceLiveOutputCard: View {
    let task: ScheduledTask
    let showLogs: (UUID) -> Void
    @ObservedObject private var liveOutput = LiveOutputManager.shared

    var body: some View {
        let latest = task.executionLogs
            .filter { $0.modelContext != nil }
            .max(by: { $0.startedAt < $1.startedAt })
        let isLive = latest?.status == .running && liveOutput.isTracking(task.id)
        let stdout = isLive ? liveOutput.stdout(for: task.id) : latest?.stdout
        let stderr = isLive ? liveOutput.stderr(for: task.id) : latest?.stderr
        // Keep both streams visible, including errors when stdout has content.
        let output = [stdout, stderr]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")

        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.tr("task.detail.live_output"), systemImage: "text.alignleft")
                        .font(.headline)
                    Spacer()
                    if let latest {
                        StatusBadge(status: latest.status, compact: true)
                    }
                }

                if output.isEmpty {
                    Text(L10n.tr(latest?.status == .running
                        ? "task.detail.live_output.waiting"
                        : latest == nil ? "task.detail.no_logs" : "task.detail.last_output.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    // The existing viewer appends efficiently and follows the
                    // latest lines unless the user scrolls up to inspect them.
                    LogTextView(text: output,
                                font: .monospacedSystemFont(ofSize: 11, weight: .regular))
                        .id(task.id)
                        .frame(height: 220)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                }

                if let latest {
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                            ToastCenter.shared.success(L10n.tr("task.detail.last_output.copied"))
                        } label: {
                            Label(L10n.tr("task.detail.last_output.copy"), systemImage: "doc.on.doc")
                        }
                        .disabled(output.isEmpty)
                        .pointerCursor()

                        Button {
                            showLogs(latest.id)
                        } label: {
                            Label(L10n.tr("task.detail.view_logs"), systemImage: "list.bullet.rectangle")
                        }
                        .pointerCursor()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
