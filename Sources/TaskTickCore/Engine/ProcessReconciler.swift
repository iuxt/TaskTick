import Foundation
import Darwin

/// PID-level liveness + start-time fingerprinting for the running-process
/// reconciler. All functions are pure and safe to call from any thread.
///
/// `isAlive` is a POSIX `kill(pid, 0)` probe — returns true iff a process
/// with that PID exists AND we have permission to signal it. On macOS,
/// processes started by the same user (the only ones TaskTick spawns) are
/// always signalable, so EPERM here means the PID has been recycled to a
/// process owned by another user — treat that as "not the same process".
///
/// `startTime` runs `ps -p <pid> -o lstart=` and returns the trimmed output
/// (e.g. `Mon May 12 14:23:45 2026`). The value is locale-formatted but
/// stable across calls for the same process, which is all the reconciler
/// needs — we compare strings, never parse.
public enum ProcessReconciler {
    /// Keep the fingerprint with the PID for the entire adopted lifetime.
    public struct Identity: Sendable, Equatable {
        public let pid: Int32
        public let startTime: String

        public init(pid: Int32, startTime: String) {
            self.pid = pid
            self.startTime = startTime
        }

        public var isCurrent: Bool {
            ProcessReconciler.isAlive(pid: pid)
                && ProcessReconciler.startTime(pid: pid) == startTime
        }

        @discardableResult
        public func signalGroup(_ signal: Int32) -> Bool {
            guard isCurrent, getpgid(pid) == pid else { return false }
            return kill(-pid, signal) == 0
        }

        /// Capture before sending TERM: the leader may exit before escalation.
        /// A surviving member's kernel start time then proves group ownership.
        public func captureGroup() -> GroupIdentity? {
            guard isCurrent, getpgid(pid) == pid else { return nil }
            let capacity = max(64, Int(proc_listpgrppids(pid, nil, 0)))
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { return nil }
            let members = pids.prefix(Int(count)).compactMap { GroupIdentity.Member(pid: $0, group: pid) }
            guard isCurrent, !members.isEmpty else { return nil }
            return GroupIdentity(pid: pid, members: members)
        }
    }

    public struct GroupIdentity: Sendable {
        public let pid: Int32
        fileprivate let members: [Member]

        fileprivate struct Member: Sendable {
            let pid: Int32
            let seconds: UInt64
            let microseconds: UInt64

            init?(pid: Int32, group: Int32) {
                guard let info = Self.info(pid: pid), info.pbi_pgid == UInt32(group) else { return nil }
                self.pid = pid
                seconds = info.pbi_start_tvsec
                microseconds = info.pbi_start_tvusec
            }

            func isCurrent(in group: Int32) -> Bool {
                guard let info = Self.info(pid: pid) else { return false }
                return info.pbi_pgid == UInt32(group)
                    && info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds
            }

            private static func info(pid: Int32) -> proc_bsdinfo? {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
                return info
            }
        }

        /// Never trust a bare PGID after its leader exits. At least one captured
        /// member must still have the same kernel identity and group membership.
        @discardableResult
        public func signal(_ signal: Int32) -> Bool {
            guard members.contains(where: { $0.isCurrent(in: pid) }) else { return false }
            return kill(-pid, signal) == 0
        }
    }

    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): no signal sent, just permission/existence check.
        // Returns 0 on success. ESRCH = no such process. EPERM = exists but
        // we can't signal it (different uid) — for our purposes, treat as
        // "not us, don't touch".
        if kill(pid, 0) == 0 { return true }
        return false
    }

    public static func startTime(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "lstart="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // swallow stderr ("no such process" noise)
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        // ps exits non-zero (1) when the pid doesn't exist.
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
