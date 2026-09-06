import CryptoKit
import Foundation
import SwiftData
import os
import TaskTickCore

/// Manages automatic data backups.
///
/// Backups are written as a single self-contained JSON file per snapshot. This is
/// deliberately decoupled from SwiftData's on-disk SQLite layout — earlier versions
/// `cp`'d the raw `.store/.shm/.wal` files, which inherits every failure mode of the
/// live database (WAL loss, fd/inode divergence on macOS 15, schema migration corruption).
/// When the live store ever appeared empty, the very next scheduled backup would
/// faithfully capture the empty state and overwrite previous good backups.
///
/// Going through `context.fetch` reads tasks via SwiftData's open file descriptor —
/// which is the in-memory snapshot the user actually sees — so even if the on-disk
/// `.store` file has been replaced underneath us, a JSON backup still captures the
/// real data. Empty-data protection then refuses to overwrite a non-empty backup
/// with a zero-task snapshot.
@MainActor
final class DatabaseBackup: ObservableObject {
    static let shared = DatabaseBackup()

    private static let logger = Logger(subsystem: "com.iuxt.TaskTick", category: "DatabaseBackup")
    private static let fileExtension = "tasktickbackup"
    /// Filenames look like `2026-04-21T10-30-45Z.tasktickbackup` so they sort lexically.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var timer: Timer?
    private var modelContext: ModelContext?
    private var isRestoring = false

    // MARK: - Settings (persisted via UserDefaults)

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "backupEnabled") }
    }
    @Published var intervalHours: Int {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "backupIntervalHours") }
    }
    @Published var maxBackups: Int {
        didSet { UserDefaults.standard.set(maxBackups, forKey: "backupMaxCount") }
    }
    @Published var customDirectory: String {
        didSet { UserDefaults.standard.set(customDirectory, forKey: "backupDirectory") }
    }
    @Published var lastBackupDate: Date?
    @Published var nextBackupDate: Date?
    /// Set when the most recent automatic backup was skipped to protect against
    /// overwriting good data. UI surfaces this so the user knows why their backup
    /// list isn't growing.
    @Published var lastSkipReason: String?
    /// True when the last performBackup call short-circuited because content hadn't
    /// changed since the previous snapshot. Lets the manual "Backup Now" alert tell
    /// the user "nothing to do" instead of pretending it wrote a new file.
    @Published var lastBackupWasDedup: Bool = false

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "backupEnabled") as? Bool ?? true
        self.intervalHours = UserDefaults.standard.object(forKey: "backupIntervalHours") as? Int ?? 24
        self.maxBackups = UserDefaults.standard.object(forKey: "backupMaxCount") as? Int ?? 5
        let bundleId = Bundle.main.bundleIdentifier ?? "com.iuxt.TaskTick"
        let subDir = bundleId.hasSuffix(".dev") ? "backups-dev" : "backups"
        let defaultDir = NSHomeDirectory() + "/.tasktick/" + subDir
        self.customDirectory = UserDefaults.standard.string(forKey: "backupDirectory") ?? defaultDir
    }

    // MARK: - Lifecycle

    /// `storeURL` is no longer used (kept for API compat with the old call site).
    func configure(storeURL: URL, modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    func startScheduledBackups() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else {
            nextBackupDate = nil
            return
        }

        let interval = TimeInterval(intervalHours * 3600)
        let backups = listBackups()
        let lastBackup = backups.first
        lastBackupDate = lastBackup?.date

        let firstDelay: TimeInterval
        if let lastDate = lastBackup?.date {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed >= interval {
                performBackup()
                firstDelay = interval
            } else {
                firstDelay = interval - elapsed
            }
        } else {
            performBackup()
            firstDelay = interval
        }

        nextBackupDate = Date().addingTimeInterval(firstDelay)
        timer = Timer.scheduledTimer(withTimeInterval: firstDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performBackup()
                self?.startPeriodicTimer(interval: interval)
            }
        }
    }

    private func startPeriodicTimer(interval: TimeInterval) {
        nextBackupDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performBackup()
                self?.nextBackupDate = Date().addingTimeInterval(interval)
            }
        }
    }

    func stopScheduledBackups() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Backup

    /// Writes a JSON backup. Returns true on success. Returns false (and sets
    /// `lastSkipReason`) when a non-empty previous backup would be overwritten by
    /// an empty snapshot — the safety guard that addresses the original bug.
    @discardableResult
    func performBackup() -> Bool {
        guard !isRestoring else { return false }
        guard let modelContext else {
            Self.logger.warning("No modelContext configured, skipping backup")
            return false
        }

        let tasks: [ScheduledTask]
        do {
            tasks = try modelContext.fetch(FetchDescriptor<ScheduledTask>())
        } catch {
            Self.logger.error("Pre-backup fetch failed, skipping: \(error.localizedDescription)")
            return false
        }

        // Empty-data protection: if we're about to write zero tasks but a previous
        // backup might have data, refuse the overwrite. Treats unknown task counts
        // (legacy `.store` dirs, partially-written JSON) as "possibly non-empty" so
        // a corrupted live store can never silently clobber the last good snapshot.
        if tasks.isEmpty {
            let existing = listBackups()
            if let latest = existing.first {
                let mightHaveData = latest.taskCount.map { $0 > 0 } ?? true
                if mightHaveData {
                    let countDesc = latest.taskCount.map(String.init) ?? "unknown"
                    let reason = "Live database has 0 tasks but most recent backup has \(countDesc). Refusing to overwrite."
                    Self.logger.warning("\(reason)")
                    lastSkipReason = reason
                    return false
                }
            }
        }

        let exportedTasks = tasks.map(TaskExporter.makeExported)

        // Dedup: if user content hasn't changed since the last successful backup,
        // skip the write. ExportedTask deliberately excludes runtime fields
        // (lastRunAt / executionCount / nextRunAt — see TaskExporter.makeExported)
        // so the hash only flips when the user actually edits something.
        let currentHash = Self.computeContentHash(tasks: exportedTasks)
        if let currentHash,
           let latest = listBackups().first,
           latest.format == .json,
           Self.backup(at: latest.url, matchesContentHash: currentHash) {
            Self.logger.info("Backup skipped: content unchanged since last snapshot (\(currentHash.prefix(8)))")
            lastBackupDate = Date()
            lastBackupWasDedup = true
            lastSkipReason = nil
            return true
        }

        let payload = BackupPayload(
            format: BackupPayload.currentFormat,
            appVersion: appVersion,
            exportDate: Date(),
            taskCount: exportedTasks.count,
            tasks: exportedTasks,
            contentHash: currentHash
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            Self.logger.error("Backup encode failed: \(error.localizedDescription)")
            return false
        }

        let fm = FileManager.default
        let backupDir = URL(fileURLWithPath: customDirectory)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create backup directory: \(error.localizedDescription)")
            return false
        }

        let timestamp = Self.timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = backupDir.appendingPathComponent("\(timestamp).\(Self.fileExtension)")

        do {
            // Atomic write: data lands at a temp path then is renamed into place,
            // so a crash mid-write never leaves a half-written .tasktickbackup behind.
            try data.write(to: fileURL, options: .atomic)
            Self.logger.info("Backup written to \(fileURL.path) (\(exportedTasks.count) tasks)")
            pruneOldBackups(in: backupDir)
            lastBackupDate = Date()
            lastSkipReason = nil
            lastBackupWasDedup = false
            return true
        } catch {
            Self.logger.error("Backup write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restore

    enum RestoreResult {
        case success(taskCount: Int, requiresRestart: Bool = false)
        case failed(message: String)
    }

    /// Restore from a backup file (or legacy directory). The SwiftData rewrite
    /// runs on a detached background ModelContext so the UI thread never blocks —
    /// even with a backup that wipes thousands of accumulated execution logs via
    /// cascade delete. The main `mainContext` picks up the changes through the
    /// shared ModelContainer once the background save commits.
    @discardableResult
    func restore(from entry: BackupEntry) async -> RestoreResult {
        guard !isRestoring else { return .failed(message: "A restore is already in progress.") }
        let payload: BackupPayload?
        switch entry.format {
        case .json:
            do {
                payload = try Self.readPayload(at: entry.url)
            } catch {
                return .failed(message: "Cannot read backup file: \(error.localizedDescription)")
            }
        case .legacy:
            // Legacy `.store` dirs predate the JSON format. Fall back to the old
            // file-copy restore so users with backups from v1.4.0/v1.4.1 are not
            // stranded after upgrading. Returns a sentinel that triggers an app
            // restart (legacy restore swaps SQLite files under SwiftData, which
            // can't be reloaded in-place).
            payload = nil
        }

        isRestoring = true
        let scheduler = TaskScheduler.shared
        let executor = ScriptExecutor.shared
        scheduler.pauseForRestore()
        await executor.suspendAndDrainForRestore()
        var requiresRestart = false
        defer {
            isRestoring = false
            if !requiresRestart {
                executor.resumeAfterRestore()
                scheduler.resumeAfterRestore()
            }
        }

        guard let payload else {
            let result = restoreLegacy(from: entry)
            if case .success = result { requiresRestart = true }
            return result
        }

        if TaskTickApp._needsRecovery {
            let storeURL = TaskTickApp._storeURL
            let result: RestoreResult = await Task.detached(priority: .userInitiated) {
                do {
                    try StoreRecovery.restore(payload.tasks, to: storeURL)
                    return .success(taskCount: payload.tasks.count, requiresRestart: true)
                } catch {
                    return .failed(message: "Persistent recovery failed: \(error.localizedDescription)")
                }
            }.value
            if case .success = result { requiresRestart = true }
            return result
        }

        // Heavy SwiftData work off main: capture the container on main, then detach
        // a task that builds its own ModelContext from it. Returning only the
        // primitive RestoreResult keeps the SwiftData objects on their original actor.
        guard let modelContext else { return .failed(message: "No model context configured.") }
        let container = modelContext.container
        let result: RestoreResult = await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            return Self.applyPayloadOnBackground(payload, in: bgContext)
        }.value

        guard case .success = result else { return result }

        // Restored tasks have no `nextRunAt` (we only persist user-authored config in
        // backups). Without this, the scheduler skips them — they'd display in the
        // list but never fire until the user toggled them off and back on.
        if let mainContext = self.modelContext {
            let descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.isEnabled && $0.nextRunAt == nil }
            )
            if let restoredTasks = try? mainContext.fetch(descriptor) {
                for task in restoredTasks {
                    task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                }
                try? mainContext.save()
            }
        }
        TaskScheduler.shared.rebuildSchedule()
        return result
    }

    /// Restore the most recent JSON backup, used by Recovery Mode.
    @discardableResult
    func restoreFromLatestBackup() async -> Bool {
        let backups = listBackups()
        for backup in backups {
            if case .success = await restore(from: backup) { return true }
        }
        return false
    }

    /// Background-actor implementation. Runs entirely off the main queue using a
    /// dedicated ModelContext bound to the shared container. SwiftData merges the
    /// committed changes back into the main context via the container.
    nonisolated private static func applyPayloadOnBackground(_ payload: BackupPayload, in context: ModelContext) -> RestoreResult {
        let existingTasks: [ScheduledTask]
        do {
            existingTasks = try context.fetch(FetchDescriptor<ScheduledTask>())
        } catch {
            return .failed(message: "Failed to read existing tasks: \(error.localizedDescription)")
        }

        // Insert new first, then delete old. If save fails the rollback leaves the
        // original data intact (vs. delete-then-insert which would wipe everything).
        for item in payload.tasks {
            let task = TaskExporter.makeTask(from: item)
            context.insert(task)
        }
        for task in existingTasks {
            context.delete(task)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            return .failed(message: "Save failed: \(error.localizedDescription)")
        }

        return .success(taskCount: payload.tasks.count)
    }

    /// Legacy restore: same logic as the old DatabaseBackup did — copy the SQLite
    /// files from the backup dir into the live store path. Returns a sentinel that
    /// the UI translates to "restart now" because SwiftData cannot reload after the
    /// underlying file changes.
    private func restoreLegacy(from entry: BackupEntry) -> RestoreResult {
        let storeURL = TaskTickApp._storeURL
        let baseName = storeURL.lastPathComponent
        let backupStore = entry.url.appendingPathComponent(baseName)
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupStore.path) else {
            return .failed(message: "Legacy backup is missing the main store file")
        }

        do {
            // Since v1.4.2 the store lives in a bundleID-namespaced subdirectory.
            // Make sure it exists before writing — on a fresh install that has
            // never opened a store, the directory won't have been created yet.
            let storeDir = storeURL.deletingLastPathComponent()
            try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)

            let extensions = ["", "-shm", "-wal"]
            for ext in extensions {
                let fileURL = storeDir.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: fileURL.path) {
                    try fm.removeItem(at: fileURL)
                }
            }
            for ext in extensions {
                let sourceURL = entry.url.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: sourceURL.path) {
                    let destURL = storeDir.appendingPathComponent(baseName + ext)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }
            // Match the old behavior — flush WAL into the main file before the
            // process restarts so the next launch sees a self-contained store.
            StoreHardener.checkpoint(at: storeURL)
        } catch {
            return .failed(message: "Legacy restore failed: \(error.localizedDescription)")
        }

        // Caller (SettingsView) must trigger a restart for legacy restores.
        return .success(taskCount: 0, requiresRestart: true)
    }

    // MARK: - List Backups

    struct BackupEntry: Identifiable {
        enum Format { case json, legacy }
        let id: String
        let name: String
        let date: Date
        let sizeBytes: Int
        let url: URL
        let format: Format
        /// Only populated for JSON backups (cheap to read from the meta header).
        /// Nil for legacy entries — peeking into the SQLite file just to count rows
        /// would require opening it under a read lock and isn't worth the complexity
        /// for a deprecated format.
        let taskCount: Int?
    }

    func listBackups() -> [BackupEntry] {
        let fm = FileManager.default
        let backupDir = URL(fileURLWithPath: customDirectory)
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey, .totalFileAllocatedSizeKey]
        ) else { return [] }

        var entries: [BackupEntry] = []
        for url in contents {
            if url.pathExtension == Self.fileExtension {
                if let entry = makeJSONEntry(at: url) {
                    entries.append(entry)
                }
            } else if url.hasDirectoryPath {
                if let entry = makeLegacyEntry(at: url) {
                    entries.append(entry)
                }
            }
        }

        // Newest first. JSON filenames sort lexically (ISO timestamps); legacy dirs
        // share the same naming scheme so a single sort handles both.
        return entries.sorted { $0.name > $1.name }
    }

    func deleteBackup(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        objectWillChange.send()
    }

    // MARK: - Private helpers

    private func makeJSONEntry(at url: URL) -> BackupEntry? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0

        // Try reading the meta. If the file is corrupt or partial, still surface it
        // so the user can delete it from the UI.
        let payload = try? Self.readPayload(at: url)
        let date = payload?.exportDate ?? Self.parseDate(fromName: url.deletingPathExtension().lastPathComponent)
                   ?? (attrs?[.creationDate] as? Date) ?? Date.distantPast

        return BackupEntry(
            id: url.lastPathComponent,
            name: url.deletingPathExtension().lastPathComponent,
            date: date,
            sizeBytes: size,
            url: url,
            format: .json,
            taskCount: payload?.taskCount
        )
    }

    private func makeLegacyEntry(at url: URL) -> BackupEntry? {
        let fm = FileManager.default
        let storeURL = TaskTickApp._storeURL
        let baseName = storeURL.lastPathComponent
        let backupStore = url.appendingPathComponent(baseName)
        guard fm.fileExists(atPath: backupStore.path) else { return nil }

        var totalSize = 0
        if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for file in files {
                if let s = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int {
                    totalSize += s
                }
            }
        }

        let name = url.lastPathComponent
        let date = Self.parseDate(fromName: name)
            ?? (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            ?? Date.distantPast

        return BackupEntry(
            id: name,
            name: name,
            date: date,
            sizeBytes: totalSize,
            url: url,
            format: .legacy,
            taskCount: nil
        )
    }

    private static func parseDate(fromName name: String) -> Date? {
        // Format: "2026-04-21T10-30-45Z" — colons replaced with dashes for filename safety.
        guard let tIndex = name.firstIndex(of: "T") else { return nil }
        let datePart = name[name.startIndex...tIndex]
        let timePart = name[name.index(after: tIndex)...].replacingOccurrences(of: "-", with: ":")
        let restored = String(datePart) + timePart
        return timestampFormatter.date(from: restored)
    }

    /// Hash a snapshot of user-authored content. Returns nil only if encoding fails,
    /// in which case the caller must fall back to writing a backup unconditionally —
    /// dedup must never silently swallow a backup window when we can't prove equality.
    static func computeContentHash(tasks: [TaskExporter.ExportedTask]) -> String? {
        struct HashInput: Encodable {
            let tasks: [TaskExporter.ExportedTask]
        }
        let encoder = JSONEncoder()
        // sortedKeys + iso8601 give a deterministic byte sequence so two semantically
        // identical snapshots produce identical hashes across processes/launches.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(HashInput(tasks: tasks)) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify the actual file, not a cached preference or unverified header.
    /// Deleting, replacing, corrupting or moving a snapshot must cause a write.
    static func backup(at url: URL, matchesContentHash hash: String) -> Bool {
        guard let payload = try? readPayload(at: url),
              let actualHash = computeContentHash(tasks: payload.tasks) else { return false }
        return actualHash == hash
    }

    private static func readPayload(at url: URL) throws -> BackupPayload {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BackupPayload.self, from: data)
        guard payload.format == BackupPayload.currentFormat,
              payload.taskCount == payload.tasks.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return payload
    }

    private func pruneOldBackups(in backupDir: URL) {
        Self.pruneOldBackups(in: backupDir, keeping: maxBackups,
            legacyStoreName: TaskTickApp._storeURL.lastPathComponent)
    }

    /// Only known JSON snapshots and valid legacy store directories belong to
    /// TaskTick. In particular, never recurse into arbitrary user folders.
    static func pruneOldBackups(in directory: URL, keeping count: Int, legacyStoreName: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let backups = entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
            if values.isDirectory == true {
                guard Self.parseDate(fromName: url.lastPathComponent) != nil else { return false }
                let store = url.appendingPathComponent(legacyStoreName)
                let info = try? store.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return info?.isRegularFile == true && info?.isSymbolicLink != true
            }
            return url.pathExtension == Self.fileExtension && (try? Self.readPayload(at: url)) != nil
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(max(1, count)) {
            do { try fm.removeItem(at: old) }
            catch { Self.logger.error("Cannot prune backup: \(error.localizedDescription)") }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: - Backup Payload

/// On-disk format for a single JSON backup. Versioned via `format`; older readers
/// reject unknown formats rather than silently mis-decoding.
struct BackupPayload: Codable {
    static let currentFormat = "tasktick-backup-v1"

    let format: String
    let appVersion: String
    let exportDate: Date
    let taskCount: Int
    let tasks: [TaskExporter.ExportedTask]
    /// Optional so backups produced by older versions still decode.
    let contentHash: String?

    init(format: String,
         appVersion: String,
         exportDate: Date,
         taskCount: Int,
         tasks: [TaskExporter.ExportedTask],
         contentHash: String? = nil) {
        self.format = format
        self.appVersion = appVersion
        self.exportDate = exportDate
        self.taskCount = taskCount
        self.tasks = tasks
        self.contentHash = contentHash
    }
}
