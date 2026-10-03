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
    private let queue = DispatchQueue(label: "com.iuxt.tasktick.logwriter")
    private let maximumBytes: Int64
    private let rotationCount: Int
    private var currentBytes: Int64
    enum Stream { case stdout, stderr }
    private var stdoutDecoder = ProcessOutputDecoder()
    private var stderrDecoder = ProcessOutputDecoder()

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
    /// Each stream keeps its own ANSI and UTF-8 state between pipe reads.
    func append(_ data: Data, stream: Stream = .stdout) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.handle != nil else { return }
            let text: String
            switch stream {
            case .stdout: text = self.stdoutDecoder.decode(data)
            case .stderr: text = self.stderrDecoder.decode(data)
            }
            self.writeRotating(Data(text.utf8))
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
            var count = min(capacity, data.count - offset)
            // `data` is valid UTF-8 from UTF8StreamDecoder. Rotate before a
            // scalar rather than splitting its continuation bytes between two
            // individually-invalid log files.
            if offset + count < data.count {
                while count > 0, Self.isUTF8Continuation(data[offset + count]) {
                    count -= 1
                }
            }
            if count == 0 {
                if currentBytes > 0 {
                    rotate()
                    continue
                }
                // A pathological byte limit smaller than one scalar: keep the
                // scalar intact even if that single write exceeds the limit.
                var scalarEnd = offset + 1
                while scalarEnd < data.count, Self.isUTF8Continuation(data[scalarEnd]) {
                    scalarEnd += 1
                }
                count = scalarEnd - offset
            }
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

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }

    private func rotatedURL(_ index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }

    /// Idempotent — closes the underlying handle. Subsequent appends are
    /// no-ops. The on-disk file is left in place for the user to inspect.
    func close() {
        queue.sync { [self] in
            writeRotating(Data(stdoutDecoder.finish().utf8))
            writeRotating(Data(stderrDecoder.finish().utf8))
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
