import Foundation
import Testing
@testable import TaskTickApp

@Suite("Rotating file output")
struct LogFileWriterTests {
    @Test("Rotates at the byte limit and retains configured archives")
    func rotatesAndRetainsArchives() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("service.log").path
        let writer = try #require(LogFileWriter(
            taskName: "service",
            path: path,
            append: true,
            maximumBytes: 10,
            rotationCount: 2
        ))
        writer.append(Data("0123456789abcdefghijKLMNO".utf8))
        writer.close()

        let active = try String(contentsOfFile: path, encoding: .utf8)
        let firstArchive = try String(contentsOfFile: path + ".1", encoding: .utf8)
        let secondArchive = try String(contentsOfFile: path + ".2", encoding: .utf8)
        #expect(active == "KLMNO")
        #expect(firstArchive == "abcdefghij")
        #expect(secondArchive == "0123456789")
    }

    @Test("Append mode preserves an existing partial log")
    func appendModePreservesExistingOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("service.log")
        try Data("before\n".utf8).write(to: url)
        let writer = try #require(LogFileWriter(
            taskName: "service",
            path: url.path,
            append: true,
            maximumBytes: 1_024,
            rotationCount: 1
        ))
        writer.append(Data("after\n".utf8))
        writer.close()

        let output = try String(contentsOf: url, encoding: .utf8)
        #expect(output == "before\nafter\n")
    }
}
