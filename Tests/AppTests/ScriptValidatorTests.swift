import Testing
import Foundation
@testable import TaskTickApp

@Suite("Script validation")
struct ScriptValidatorTests {

    private func isSuccess(_ result: ScriptValidationResult) -> Bool {
        if case .success = result { return true }
        return false
    }

    @Test("A valid python script passes")
    func validPythonPasses() async {
        let result = await ScriptValidator.validate(
            scriptBody: "#!/usr/bin/env python3\nvalues = (1, 2)\nprint(sum(values))\n",
            uiShell: "/bin/zsh"
        )
        #expect(isSuccess(result), "got \(result)")
    }

    /// The reported bug: the editor validated every script with `<uiShell> -n`, so a
    /// Python file came back as `zsh: parse error near ')'` — a shell complaining
    /// about a language it was never meant to parse.
    @Test("A broken python script reports a python error, not a shell one")
    func brokenPythonReportsPythonError() async {
        let result = await ScriptValidator.validate(
            scriptBody: "#!/usr/bin/env python3\nvalues = (1, 2\n",
            uiShell: "/bin/zsh"
        )
        guard case .error(let message) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(message.contains("SyntaxError"), "should come from python: \(message)")
        #expect(!message.contains("parse error"), "the shell must not be parsing it: \(message)")
    }

    /// preRunCommand is shell code that wraps *around* the script at run time. The
    /// editor used to concatenate the two before validating, which meant any task
    /// with a preRun and a non-shell script could never validate.
    @Test("preRun does not contaminate a python script")
    func preRunDoesNotContaminatePython() async {
        let result = await ScriptValidator.validate(
            scriptBody: "#!/usr/bin/env python3\nprint((1, 2))\n",
            preRun: "export FOO=bar",
            uiShell: "/bin/zsh"
        )
        #expect(isSuccess(result), "got \(result)")
    }

    @Test("A broken preRun is still caught alongside a python script")
    func brokenPreRunStillCaught() async {
        let result = await ScriptValidator.validate(
            scriptBody: "#!/usr/bin/env python3\nprint(1)\n",
            preRun: "if [ -f x ; then",
            uiShell: "/bin/zsh"
        )
        guard case .error = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
    }

    @Test("Shell scripts validate exactly as before")
    func shellScriptsStillValidate() async {
        let ok = await ScriptValidator.validate(
            scriptBody: "#!/bin/bash\nfor i in 1 2; do echo $i; done\n",
            uiShell: "/bin/zsh"
        )
        #expect(isSuccess(ok), "got \(ok)")

        let bad = await ScriptValidator.validate(
            scriptBody: "#!/bin/bash\nif [ -f x ; then\n",
            uiShell: "/bin/zsh"
        )
        guard case .error = bad else {
            Issue.record("expected an error, got \(bad)")
            return
        }
    }

    @Test("No shebang falls back to the shell picked in the UI")
    func noShebangUsesUIShell() async {
        let result = await ScriptValidator.validate(scriptBody: "echo hi\n", uiShell: "/bin/zsh")
        #expect(isSuccess(result), "got \(result)")
    }

    /// Better to say "I can't check this" than to hand it to the wrong parser and
    /// report a confident, wrong error.
    @Test("An unknown interpreter is reported, never guessed at")
    func unknownInterpreterIsReported() async {
        let result = await ScriptValidator.validate(
            scriptBody: "#!/usr/bin/env lua\nlocal t = { 1, 2 }\n",
            uiShell: "/bin/zsh"
        )
        guard case .unsupported(let name) = result else {
            Issue.record("expected unsupported, got \(result)")
            return
        }
        #expect(name == "lua")
    }

    @Test("An empty script is rejected")
    func emptyScriptRejected() async {
        let result = await ScriptValidator.validate(scriptBody: "   \n", uiShell: "/bin/zsh")
        guard case .error = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
    }
}
