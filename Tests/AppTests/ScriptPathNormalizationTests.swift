import Testing
import Foundation
@testable import TaskTickApp

/// The script-file field accepts typed and pasted paths, so it has to cope
/// with the shapes a path arrives in: `~`, stray whitespace, shell quoting,
/// and Finder's escaped spaces. A path that survives normalization wrong
/// fails at *run* time, long after the editor accepted it.
@Suite("Script path normalization")
struct ScriptPathNormalizationTests {

    private func normalize(_ raw: String) -> String {
        TaskEditorView.normalizePath(raw)
    }

    @Test("普通绝对路径原样保留")
    func plainAbsolutePath() {
        #expect(normalize("/tmp/foo.sh") == "/tmp/foo.sh")
    }

    @Test("~ 展开为家目录")
    func tildeExpands() {
        let home = NSHomeDirectory()
        #expect(normalize("~/scripts/foo.sh") == "\(home)/scripts/foo.sh")
    }

    @Test("首尾空白被裁掉")
    func trimsWhitespace() {
        #expect(normalize("  /tmp/foo.sh  ") == "/tmp/foo.sh")
    }

    @Test("换行被裁掉（粘贴常带）")
    func trimsNewline() {
        #expect(normalize("/tmp/foo.sh\n") == "/tmp/foo.sh")
    }

    @Test("成对双引号被剥掉（shell 复制带空格路径时会加）")
    func stripsDoubleQuotes() {
        #expect(normalize("\"/tmp/my scripts/foo.sh\"") == "/tmp/my scripts/foo.sh")
    }

    @Test("成对单引号被剥掉")
    func stripsSingleQuotes() {
        #expect(normalize("'/tmp/foo.sh'") == "/tmp/foo.sh")
    }

    @Test("反斜杠转义的空格还原为真实空格（Finder 拷贝路径名）")
    func unescapesSpaces() {
        #expect(normalize("/tmp/my\\ scripts/foo.sh") == "/tmp/my scripts/foo.sh")
    }

    @Test("引号 + ~ 组合")
    func quotedTilde() {
        let home = NSHomeDirectory()
        #expect(normalize("\"~/foo.sh\"") == "\(home)/foo.sh")
    }

    @Test("空字符串保持为空，不产生伪路径")
    func emptyStaysEmpty() {
        #expect(normalize("") == "")
        #expect(normalize("   ") == "")
    }

    @Test("路径中间的引号不动（只剥首尾成对的）")
    func keepsInteriorQuotes() {
        // A filename may legitimately contain a quote; only a matched
        // surrounding pair is shell quoting.
        #expect(normalize("/tmp/wei\"rd.sh") == "/tmp/wei\"rd.sh")
    }

    @Test("只有一侧引号时不剥（不是成对引用）")
    func leavesUnmatchedQuote() {
        #expect(normalize("\"/tmp/foo.sh") == "\"/tmp/foo.sh")
    }

    @Test("规范化是幂等的")
    func isIdempotent() {
        let once = normalize("  \"~/my\\ scripts/foo.sh\"  ")
        #expect(normalize(once) == once)
    }
}
