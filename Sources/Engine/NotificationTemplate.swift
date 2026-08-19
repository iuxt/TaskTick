import Foundation
import TaskTickCore

/// Renders a task's custom reminder text (issue #48).
///
/// One template per task, shared by every delivery channel — the system
/// notification body, the Bark push body and the strong-reminder panel. The
/// channel is only a *type* of reminder; the content comes from here, so the
/// same run reads identically wherever the user sees it.
///
/// An empty template renders to `nil` and every caller falls back to its
/// built-in wording, which is what existing tasks keep doing.
enum NotificationTemplate {

    /// Placeholder names, in the order the editor hint lists them.
    /// Unknown placeholders are left verbatim in the output — a typo shows up
    /// as `{{lastline}}` in the banner instead of silently vanishing.
    static let placeholders = [
        "output", "firstLine", "lastLine", "name", "duration", "exitCode", "status"
    ]

    /// Cap for the body handed to the system notification and Bark. `{{output}}`
    /// can carry up to `ExecutionLog`'s 512 KB limit — a banner truncates that
    /// anyway, and Bark would ship the whole payload over the network. The
    /// strong-reminder panel scrolls, so it renders the untruncated text.
    static let pushBodyLimit = 2000

    struct Context {
        let taskName: String
        let stdout: String
        let stderr: String
        let exitCode: Int?
        let durationMs: Int
        let succeeded: Bool

        /// The stream this run's content comes from: a successful run speaks
        /// through stdout (stderr only when stdout carries nothing), a failed
        /// one through stderr (stdout only when stderr is silent).
        var output: String {
            if succeeded {
                return ScriptExecutor.hasMeaningfulContent(stdout) ? stdout : stderr
            }
            return ScriptExecutor.hasMeaningfulContent(stderr) ? stderr : stdout
        }
    }

    // MARK: - Rendering

    /// Substitute `{{…}}` placeholders in `template`. Returns nil when the task
    /// has no template, or when the result is blank (e.g. a template of just
    /// `{{output}}` on a silent run) — callers then use their default wording.
    static func render(_ template: String, context: Context) -> String? {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }

        let rendered = substitute(trimmedTemplate, with: values(for: context))
        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return rendered
    }

    /// Clamp a rendered body for the push-style channels (notification / Bark).
    static func clampForPush(_ body: String) -> String {
        guard body.count > pushBodyLimit else { return body }
        return String(body.prefix(pushBodyLimit)) + "…"
    }

    private static func values(for context: Context) -> [String: String] {
        let output = context.output
        return [
            "output": output,
            "firstline": firstMeaningfulLine(of: output),
            "lastline": lastMeaningfulLine(of: output),
            "name": context.taskName,
            "duration": ExecutionLog.formatDuration(context.durationMs),
            // A killed process reports no exit code; "-" keeps the sentence
            // readable instead of leaving a dangling label.
            "exitcode": context.exitCode.map(String.init) ?? "-",
            "status": L10n.tr(context.succeeded ? "notification.succeeded" : "notification.failed")
        ]
    }

    /// Replace back-to-front so a substituted value that happens to contain
    /// `{{…}}` (script output echoing a template) isn't expanded a second time.
    private static func substitute(_ template: String, with values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z]+)\s*\}\}"#) else {
            return template
        }
        let ns = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: ns.length))

        var result = template
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let range = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template)
            else { continue }
            let key = String(template[keyRange]).lowercased()
            guard let value = values[key] else { continue } // unknown → leave as typed
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    // MARK: - Line helpers

    /// First line carrying real content — blank lines and pure rule lines
    /// (`────`, `====`, `****`) are skipped so the banner doesn't lead with
    /// a script's decorative separator.
    static func firstMeaningfulLine(of text: String) -> String {
        text.components(separatedBy: .newlines).first(where: isMeaningfulLine) ?? ""
    }

    static func lastMeaningfulLine(of text: String) -> String {
        text.components(separatedBy: .newlines).last(where: isMeaningfulLine) ?? ""
    }

    private static func isMeaningfulLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let stripped = trimmed.filter { !("─═—–-=_*#~".contains($0)) }
        return !stripped.isEmpty
    }
}
