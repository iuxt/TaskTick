import SwiftUI
import TaskTickCore

/// Reusable script validation result type and runner.
enum ScriptValidationResult {
    case success
    case error(String)
    /// No known parse-only check exists for this interpreter. Surfaced as its own
    /// state rather than falling back to a shell parse — checking one language with
    /// another language's parser yields confident, wrong errors.
    case unsupported(String)
}

/// Syntax validation for a task's script.
///
/// The language comes from the script's own shebang, never from the shell picked in
/// the UI: that dropdown is populated from `/etc/shells`, so it can never read
/// "python". The old `shell.contains("python")` branch was therefore dead code and
/// every non-shell script fell through to `zsh -n`, which reports a perfectly valid
/// Python file as `parse error near ')'`.
enum ScriptValidator {

    static func validate(
        scriptBody: String,
        preRun: String = "",
        uiShell: String
    ) async -> ScriptValidationResult {
        let body = scriptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let pre = preRun.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !pre.isEmpty else { return .error("Empty script") }

        let interpreter = ScriptExecutor.parseShebang(from: scriptBody)

        // No shebang, or a shell one: preRun and the body are the same language at run
        // time, so one `-n` parse covers them together.
        guard let interpreter, !ScriptExecutor.isShellInterpreter(interpreter) else {
            let combined = pre.isEmpty ? scriptBody : pre + "\n" + scriptBody
            return await run(
                interpreter: interpreter ?? uiShell,
                arguments: ["-n"],
                stdin: combined,
                uiShell: uiShell
            )
        }

        // Non-shell script: preRun is shell code that wraps *around* it at run time,
        // so each half is checked by its own parser. Concatenating them — which the
        // editor's `currentScript` used to do — feeds `export FOO=bar` to Python and
        // fails every time.
        if !pre.isEmpty {
            let preResult = await run(
                interpreter: uiShell, arguments: ["-n"], stdin: pre, uiShell: uiShell
            )
            guard case .success = preResult else { return preResult }
        }

        guard let arguments = syntaxCheckArguments(for: interpreter) else {
            return .unsupported((interpreter as NSString).lastPathComponent)
        }
        return await run(
            interpreter: interpreter, arguments: arguments, stdin: scriptBody, uiShell: uiShell
        )
    }

    /// How to ask each interpreter for a parse-only check, script arriving on stdin.
    ///
    /// This table is necessarily hardcoded — there's no generic way to ask a binary
    /// "how do you syntax-check?". Anything not listed is reported as unsupported
    /// instead of guessed at.
    private static func syntaxCheckArguments(for interpreter: String) -> [String]? {
        let name = (interpreter as NSString).lastPathComponent
        if name.hasPrefix("python") {
            // compile() parses without executing. py_compile is avoided deliberately:
            // it wants to write a .pyc beside a real file, which stdin isn't.
            return ["-c", #"import sys; compile(sys.stdin.read(), "<script>", "exec")"#]
        }
        switch name {
        case "node": return ["--check", "/dev/stdin"]
        case "ruby", "perl": return ["-c"]
        default: return nil
        }
    }

    /// Runs the checker with the script on stdin.
    ///
    /// An absolute interpreter is launched directly. A bare name — from
    /// `#!/usr/bin/env python3` — goes through a login shell instead, so it resolves
    /// against the same PATH the script will see when it actually runs; `exec` hands
    /// stdin straight through to the interpreter.
    private static func run(
        interpreter: String,
        arguments: [String],
        stdin: String,
        uiShell: String
    ) async -> ScriptValidationResult {
        let process = Process()
        if interpreter.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: interpreter)
            process.arguments = arguments
        } else {
            let command = "exec " + ([interpreter] + arguments)
                .map(ScriptExecutor.singleQuoted)
                .joined(separator: " ")
            process.executableURL = URL(fileURLWithPath: uiShell)
            process.arguments = [
                "-l", "-c", ScriptExecutor.environmentPrelude(for: uiShell) + command
            ]
        }

        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inputPipe.fileHandleForWriting.closeFile()
            // Read before waiting: a checker that writes more than the pipe buffer
            // would otherwise block forever on a full pipe while we wait for it.
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 { return .success }
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .error(message.isEmpty ? "Exit code: \(process.terminationStatus)" : message)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Reusable validation button + result display row.
struct ScriptValidationRow: View {
    let script: String
    let shell: String
    @State private var isValidating = false
    @State private var result: ScriptValidationResult?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                validate()
            } label: {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.tr("editor.script.validate"))
                }
            }
            .disabled(isValidating || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()

            if let result {
                ScriptValidationResultLabel(result: result)
            }

            Spacer()
        }
    }

    private func validate() {
        isValidating = true
        result = nil
        let s = script
        let sh = shell
        Task.detached {
            let r = await ScriptValidator.validate(scriptBody: s, uiShell: sh)
            await MainActor.run {
                result = r
                isValidating = false
            }
        }
    }
}

/// Shared rendering of a validation outcome, so every screen showing a result
/// stays in step when a new case is added.
struct ScriptValidationResultLabel: View {
    let result: ScriptValidationResult

    var body: some View {
        switch result {
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text(L10n.tr("editor.script.valid"))
            }
            .font(.caption)
            .foregroundStyle(.green)
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                Text(message)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.red)
        case .unsupported(let interpreter):
            HStack(spacing: 4) {
                Image(systemName: "info.circle.fill")
                Text(L10n.tr("editor.script.validate.unsupported", interpreter))
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
