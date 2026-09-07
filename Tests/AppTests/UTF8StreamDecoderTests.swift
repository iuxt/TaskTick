import Foundation
import Testing
@testable import TaskTickApp

@Suite("Incremental UTF-8 streaming")
struct UTF8StreamDecoderTests {
    @Test("A scalar split across pipe chunks is decoded once without replacement characters")
    func splitScalar() {
        let bytes = Array("中文🙂".utf8)
        var decoder = UTF8StreamDecoder()
        var output = ""
        for byte in bytes {
            output += decoder.decode(Data([byte]))
        }
        output += decoder.finish()
        #expect(output == "中文🙂")
        #expect(!output.contains("�"))
    }

    @Test("Live output preserves a scalar split across callbacks")
    @MainActor
    func liveOutputSplitScalar() {
        let id = UUID()
        let manager = LiveOutputManager.shared
        manager.startTracking(taskId: id)
        defer { manager.stopTracking(taskId: id) }
        let bytes = Array("🙂".utf8)
        manager.appendStdout(taskId: id, data: Data(bytes.prefix(2)))
        #expect(manager.stdout(for: id) == nil)
        manager.appendStdout(taskId: id, data: Data(bytes.suffix(2)))
        #expect(manager.stdout(for: id) == "🙂")
    }

    @Test("File writer preserves Unicode split across appends")
    func fileWriterSplitScalar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("unicode.log").path
        let writer = try #require(LogFileWriter(taskName: "unicode", path: path))
        let bytes = Array("A中文🙂Z".utf8)
        for byte in bytes { writer.append(Data([byte])) }
        writer.close()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "A中文🙂Z")
    }
}
