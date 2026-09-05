import XCTest
@testable import tasktick

final class TaskDTOTests: XCTestCase {
    func testEncodesTaskWithAllFields() throws {
        let dto = TaskDTO(
            id: UUID(uuidString: "A3F9C200-0000-0000-0000-000000000000")!,
            shortId: "a3f9",
            name: "Deploy Web",
            kind: .scheduled,
            enabled: true,
            status: .idle,
            scheduleSummary: "Daily at 09:00",
            lastRunAt: Date(timeIntervalSince1970: 1_715_175_121),
            lastRunDurationSec: 47,
            lastExitCode: 0,
            createdAt: Date(timeIntervalSince1970: 1_711_966_800)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dto)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"id\":\"A3F9C200-0000-0000-0000-000000000000\""))
        XCTAssertFalse(json.contains("\"serialNumber\""))
        XCTAssertTrue(json.contains("\"shortId\":\"a3f9\""))
        XCTAssertTrue(json.contains("\"kind\":\"scheduled\""))
        XCTAssertTrue(json.contains("\"status\":\"idle\""))
    }

    func testRoundTripIdleTaskWithNoLastRun() throws {
        let dto = TaskDTO(
            id: UUID(),
            shortId: "abcd",
            name: "Untouched",
            kind: .manual,
            enabled: false,
            status: .idle,
            scheduleSummary: "Manual",
            lastRunAt: nil,
            lastRunDurationSec: nil,
            lastExitCode: nil,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(TaskDTO.self, from: encoder.encode(dto))
        XCTAssertEqual(roundTripped.id, dto.id)
        XCTAssertNil(roundTripped.lastRunAt)
        XCTAssertEqual(roundTripped.kind, .manual)
    }
}
