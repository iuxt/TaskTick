import Foundation
import TaskTickCore

/// Streams a single running script's stdout/stderr to a plain-text log file
/// under `~/Library/Logs/TaskTick/`. Designed for the manual-script /
/// dev-server scenario where the user wants `tail -f` from a terminal or
/// drag the file into Console.app.
///
/// Manual tasks truncate on each run. Background programs append and can
/// rotate by size. Failure to open or write is silently swallowed: logging
/// breakage must never take down a task run.
final class LogFileWriter: @unchecked Sendable {
    let fileURL: URL
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "com.lifedever.tasktick.logwriter")
    private let maximumBytes: Int64
    private let rotationCount: Int
    private var currentBytes: Int64
    /// Holds the tail of a chunk that might be the start of an ANSI escape
    /// sequence split across pipe reads. Without this, a chunk ending in
    /// `\x1B[0;32` followed by `m\nlog text\n` would have the head ESC
    /// orphaned (unstrippable) and the tail's `m` stranded as visible junk.
    private var pendingEscape = ""

    init?(
        taskName: String,
        taskId: UUID? = nil,
        path: String? = nil,
        append: Bool = false,
        maximumBytes: Int64 = 0,
        rotationCount: Int = 0
    ) {
        let url: URL
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            url = URL(fileURLWithPath: expanded)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            guard let defaultURL = Self.fileURL(for: taskName, taskId: taskId) else { return nil }
            url = defaultURL
        }
        let fm = FileManager.default
        if !append, fm.fileExists(atPath: url.path) {
            guard (try? Data().write(to: url)) != nil else { return nil }
        } else if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        if append { _ = try? handle.seekToEnd() }
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        self.fileURL = url
        self.handle = handle
        self.maximumBytes = max(0, maximumBytes)
        self.rotationCount = max(0, rotationCount)
        self.currentBytes = size
    }

    /// Append a chunk. Safe to call from any thread; serialized through an
    /// internal queue so concurrent stdout/stderr handlers don't interleave
    /// inside a single write() syscall.
    ///
    /// ANSI escape codes are stripped before writing — the file is meant to
    /// be opened in Console.app or `cat`, neither of which renders escape
    /// sequences. Terminal users running `tail -f` lose color, which is
    /// the lesser evil. Sequences split across pipe reads (rare but real)
    /// are buffered via `pendingEscape`.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let raw = String(decoding: data, as: UTF8.self)
            let combined = self.pendingEscape + raw
            let (safe, pending) = Self.splitOnIncompleteEscape(combined)
            self.pendingEscape = pending
            let cleaned = stripANSI(safe)
            guard !cleaned.isEmpty else { return }
            self.writeRotating(Data(cleaned.utf8))
        }
    }

    /// Writes all bytes while keeping each active file at or below the limit
    /// (unless rotation is disabled). Large pipe chunks are split across
    /// rotations rather than temporarily exceeding the configured maximum.
    private func writeRotating(_ data: Data) {
        guard handle != nil else { return }
        guard maximumBytes > 0 else {
            try? handle?.write(contentsOf: data)
            currentBytes += Int64(data.count)
            return
        }

        var offset = 0
        while offset < data.count {
            if currentBytes >= maximumBytes {
                rotate()
            }
            let capacity = Int(maximumBytes - currentBytes)
            guard capacity > 0 else { return }
            let count = min(capacity, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + count))
            do {
                try handle?.write(contentsOf: chunk)
                currentBytes += Int64(count)
                offset += count
            } catch {
                return
            }
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default

        if rotationCount > 0 {
            for index in stride(from: rotationCount, through: 1, by: -1) {
                let destination = rotatedURL(index)
                let source = index == 1 ? fileURL : rotatedURL(index - 1)
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                if fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: source, to: destination)
                }
            }
        } else {
            try? fm.removeItem(at: fileURL)
        }

        guard fm.createFile(atPath: fileURL.path, contents: nil),
              let newHandle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle = newHandle
        currentBytes = 0
    }

    private func rotatedURL(_ index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }

    /// Hold back any trailing partial ANSI sequence so the next chunk can
    /// reassemble and strip it. Recognizes the three forms TaskTick's
    /// `stripANSI()` regex covers: CSI (`ESC [ … letter`), OSC
    /// (`ESC ] … BEL`), and the 3-byte charset selectors (`ESC ( X` /
    /// `ESC ) X`). Anything else falls through as "complete" — those
    /// sequences are rare and would just appear inline as plain text.
    private static func splitOnIncompleteEscape(_ text: String) -> (safe: String, pending: String) {
        guard let escIdx = text.lastIndex(of: "\u{1B}") else {
            return (text, "")
        }
        let afterEsc = text[text.index(after: escIdx)...]
        let head = String(text[..<escIdx])
        let tail = String(text[escIdx...])

        guard let firstByte = afterEsc.first else {
            // Bare ESC at end — definitely incomplete.
            return (head, tail)
        }

        switch firstByte {
        case "[":
            // CSI: complete iff we've seen the final letter.
            if afterEsc.dropFirst().contains(where: { $0.isASCII && $0.isLetter }) {
                return (text, "")
            }
            return (head, tail)
        case "]":
            // OSC: terminated by BEL (\x07).
            if afterEsc.contains("\u{07}") {
                return (text, "")
            }
            return (head, tail)
        case "(", ")":
            // Charset selector: ESC + paren + 1 byte.
            if afterEsc.count >= 2 {
                return (text, "")
            }
            return (head, tail)
        default:
            return (text, "")
        }
    }

    /// Idempotent — closes the underlying handle. Subsequent appends are
    /// no-ops. The on-disk file is left in place for the user to inspect.
    func close() {
        queue.sync { [self] in
            // A partial escape is terminal decoration, not user output; drop it.
            pendingEscape = ""
            try? handle?.close()
            handle = nil
        }
    }

    deinit {
        // Defensive: `close()` should have been called explicitly when the
        // process ended, but if the executor was deallocated mid-flight we
        // still want the fd released so the file isn't held open forever.
        try? handle?.close()
    }

    // MARK: - Static helpers

    /// `~/Library/Logs/TaskTick/<bundle-id>/`. Returns nil only if the user's
    /// Library directory itself can't be located or created — extremely rare.
    /// Bundle-ID subdir keeps dev / release log files isolated. Pre-bundle-ID
    /// logs at `~/Library/Logs/TaskTick/<slug>.log` are orphaned; acceptable
    /// per the comment above that log files are ephemeral.
    static func logsDirectory() -> URL? {
        let fm = FileManager.default
        guard let lib = try? fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let bundleId = BundleContext.bundleID
        let dir = lib.appendingPathComponent("Logs/TaskTick/\(bundleId)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Map a user-visible task name to a filesystem-safe filename stem.
    /// Keeps CJK and most printable characters — only neutralizes the few
    /// that confuse macOS (`/`, `:`, `\`) plus control characters. Falls
    /// back to "task" when sanitization leaves an empty string.
    static func slug(for taskName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
        var result = ""
        for scalar in taskName.unicodeScalars {
            result.unicodeScalars.append(forbidden.contains(scalar) ? "-" : scalar)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "task" : trimmed
    }

    /// URL of a task's log file (without checking existence). Used by views
    /// that want to surface the path even when no run has happened yet.
    static func fileURL(for taskName: String, taskId: UUID? = nil) -> URL? {
        guard let dir = logsDirectory() else { return nil }
        let suffix = taskId.map { "-\($0.uuidString.prefix(8).lowercased())" } ?? ""
        return dir.appendingPathComponent("\(slug(for: taskName))\(suffix).log")
    }

    /// Best-effort cleanup when a task is deleted. Logs leftover from
    /// renames remain — those are handled by a separate periodic sweep
    /// (not yet implemented; orphans cost only a few MB).
    static func deleteFile(
        for taskName: String,
        taskId: UUID? = nil,
        path: String? = nil,
        rotationCount: Int = 0
    ) {
        let url: URL?
        if let path, !path.isEmpty {
            url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else {
            url = fileURL(for: taskName, taskId: taskId)
        }
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        if rotationCount > 0 {
            for index in 1...rotationCount {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".\(index)"))
            }
        }
    }
}
