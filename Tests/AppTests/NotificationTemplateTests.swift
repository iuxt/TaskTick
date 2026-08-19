import XCTest
@testable import TaskTickApp

/// Custom reminder content shared by every channel — issue #48.
final class NotificationTemplateTests: XCTestCase {

    private func context(
        name: String = "Backup",
        stdout: String = "",
        stderr: String = "",
        exitCode: Int? = 0,
        durationMs: Int = 1500,
        succeeded: Bool = true
    ) -> NotificationTemplate.Context {
        NotificationTemplate.Context(
            taskName: name,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            durationMs: durationMs,
            succeeded: succeeded
        )
    }

    // MARK: - Fallback to channel defaults

    func testEmptyTemplateRendersNil() {
        XCTAssertNil(NotificationTemplate.render("", context: context(stdout: "done")))
    }

    func testWhitespaceOnlyTemplateRendersNil() {
        XCTAssertNil(NotificationTemplate.render("  \n\t ", context: context(stdout: "done")))
    }

    /// A template made only of placeholders that resolve to nothing must fall
    /// back to the channel's own wording rather than showing a blank banner.
    func testTemplateResolvingToBlankRendersNil() {
        XCTAssertNil(NotificationTemplate.render("{{output}}", context: context(stdout: "   ")))
    }

    // MARK: - Substitution

    func testFixedTextPassesThroughUnchanged() {
        let rendered = NotificationTemplate.render("备份完成，请检查", context: context(stdout: "500 lines of noise"))
        XCTAssertEqual(rendered, "备份完成，请检查")
    }

    func testOutputPlaceholderUsesStdoutOnSuccess() {
        let rendered = NotificationTemplate.render(
            "结果：{{output}}",
            context: context(stdout: "42 files", stderr: "warning noise")
        )
        XCTAssertEqual(rendered, "结果：42 files")
    }

    /// Failed runs speak through stderr — that's where the reason lives.
    func testOutputPlaceholderUsesStderrOnFailure() {
        let rendered = NotificationTemplate.render(
            "失败：{{output}}",
            context: context(stdout: "partial progress", stderr: "permission denied", exitCode: 1, succeeded: false)
        )
        XCTAssertEqual(rendered, "失败：permission denied")
    }

    func testOutputFallsBackToOtherStreamWhenPreferredIsEmpty() {
        let success = NotificationTemplate.render(
            "{{output}}",
            context: context(stdout: "  \n", stderr: "from stderr")
        )
        XCTAssertEqual(success, "from stderr")

        let failure = NotificationTemplate.render(
            "{{output}}",
            context: context(stdout: "from stdout", stderr: "", exitCode: 1, succeeded: false)
        )
        XCTAssertEqual(failure, "from stdout")
    }

    func testFirstAndLastLineSkipRulesAndBlanks() {
        let output = """

        ────────────────
        started sync
        transferred 42 files
        ================

        """
        XCTAssertEqual(
            NotificationTemplate.render("{{firstLine}}", context: context(stdout: output)),
            "started sync"
        )
        XCTAssertEqual(
            NotificationTemplate.render("{{lastLine}}", context: context(stdout: output)),
            "transferred 42 files"
        )
    }

    func testNameDurationAndExitCodePlaceholders() {
        let rendered = NotificationTemplate.render(
            "{{name}} · {{duration}} · {{exitCode}}",
            context: context(name: "Nightly Backup", stdout: "ok", exitCode: 3, durationMs: 1500)
        )
        XCTAssertEqual(rendered, "Nightly Backup · 1.5s · 3")
    }

    /// A killed process has no exit code; the sentence must stay readable.
    func testMissingExitCodeRendersDash() {
        let rendered = NotificationTemplate.render(
            "code={{exitCode}}",
            context: context(stdout: "ok", exitCode: nil)
        )
        XCTAssertEqual(rendered, "code=-")
    }

    func testStatusPlaceholderIsSubstituted() {
        let rendered = NotificationTemplate.render("[{{status}}]", context: context(stdout: "ok"))
        XCTAssertNotNil(rendered)
        XCTAssertFalse(rendered?.contains("{{status}}") ?? true)
        XCTAssertFalse(rendered?.contains("[]") ?? true)
    }

    func testPlaceholderIsCaseInsensitiveAndToleratesInnerSpaces() {
        let rendered = NotificationTemplate.render(
            "{{ OUTPUT }}/{{LastLine}}",
            context: context(stdout: "one\ntwo")
        )
        XCTAssertEqual(rendered, "one\ntwo/two")
    }

    /// A typo must stay visible instead of silently disappearing.
    func testUnknownPlaceholderIsLeftVerbatim() {
        let rendered = NotificationTemplate.render(
            "{{nope}} {{name}}",
            context: context(name: "Task", stdout: "ok")
        )
        XCTAssertEqual(rendered, "{{nope}} Task")
    }

    /// Script output that happens to contain a placeholder must not be expanded.
    func testSubstitutedValuesAreNotReexpanded() {
        let rendered = NotificationTemplate.render(
            "{{output}}",
            context: context(name: "Task", stdout: "literal {{name}} here")
        )
        XCTAssertEqual(rendered, "literal {{name}} here")
    }

    func testMultiplePlaceholdersOnOneLine() {
        let rendered = NotificationTemplate.render(
            "{{name}}: {{firstLine}} ({{duration}})",
            context: context(name: "Sync", stdout: "done\nextra", durationMs: 2000)
        )
        XCTAssertEqual(rendered, "Sync: done (2s)")
    }

    // MARK: - Push clamping

    func testClampLeavesShortBodiesAlone() {
        XCTAssertEqual(NotificationTemplate.clampForPush("short"), "short")
    }

    /// stdout is capped at 512 KB; banners and Bark must not carry all of it.
    func testClampTruncatesOversizedBody() {
        let body = String(repeating: "x", count: NotificationTemplate.pushBodyLimit + 500)
        let clamped = NotificationTemplate.clampForPush(body)
        XCTAssertEqual(clamped.count, NotificationTemplate.pushBodyLimit + 1)
        XCTAssertTrue(clamped.hasSuffix("…"))
    }
}
