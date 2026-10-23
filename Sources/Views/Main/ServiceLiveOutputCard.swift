import SwiftUI
import TaskTickCore

/// Observe streaming updates here so each flush only redraws the log card.
struct ServiceLiveOutputCard: View {
    let task: ScheduledTask
    @ObservedObject private var scheduler = TaskScheduler.shared
    @ObservedObject private var liveOutput = LiveOutputManager.shared

    var body: some View {
        let isRunning = scheduler.runningTaskIDs.contains(task.id)
        let stdout = liveOutput.stdout(for: task.id)
        let stderr = liveOutput.stderr(for: task.id)
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
                    if isRunning {
                        StatusBadge(status: .running, compact: true)
                    } else {
                        Text(L10n.tr("service.stopped"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if output.isEmpty {
                    Text(L10n.tr(isRunning
                        ? "task.detail.live_output.waiting"
                        : "task.detail.last_output.empty"))
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

                if !output.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        ToastCenter.shared.success(L10n.tr("task.detail.last_output.copied"))
                    } label: {
                        Label(L10n.tr("task.detail.last_output.copy"), systemImage: "doc.on.doc")
                    }
                    .pointerCursor()
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
