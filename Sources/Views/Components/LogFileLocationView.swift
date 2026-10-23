import SwiftUI
import TaskTickCore

/// Opens the exact file represented by an execution-history row.
struct LogFileLocationView: View {
    let path: String

    var body: some View {
        HStack(spacing: 8) {
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Label(L10n.tr("task.detail.live_log.reveal"), systemImage: "folder")
            }
            .controlSize(.small)
            .pointerCursor()
        }
    }
}
