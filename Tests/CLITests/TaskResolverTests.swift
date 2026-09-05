import XCTest
@testable import tasktick

final class TaskResolverTests: XCTestCase {
    private struct Sample {
        let id: UUID
        let name: String
    }

    private let samples: [Sample] = [
        .init(id: UUID(uuidString: "A3F9C200-0000-0000-0000-000000000001")!, name: "Deploy Web"),
        .init(id: UUID(uuidString: "B1C40000-0000-0000-0000-000000000002")!, name: "Backup Photos"),
        .init(id: UUID(uuidString: "C7E20000-0000-0000-0000-000000000003")!, name: "Sync Vault")
    ]

    private func resolver() -> TaskResolver<Sample> {
        TaskResolver(items: samples,
                     idOf: { $0.id },
                     nameOf: { $0.name })
    }

    func testResolvesByFullUUID() throws {
        let r = try resolver().resolve("A3F9C200-0000-0000-0000-000000000001")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testResolvesByShortIdPrefix() throws {
        let r = try resolver().resolve("a3f9")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testResolvesByExactName() throws {
        let r = try resolver().resolve("Backup Photos")
        XCTAssertEqual(r.id.uuidString, "B1C40000-0000-0000-0000-000000000002")
    }

    func testResolvesByCaseInsensitiveName() throws {
        let r = try resolver().resolve("backup photos")
        XCTAssertEqual(r.id.uuidString, "B1C40000-0000-0000-0000-000000000002")
    }

    func testResolvesByFuzzy() throws {
        let r = try resolver().resolve("depl")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testThrowsOnNoMatch() {
        XCTAssertThrowsError(try resolver().resolve("zzzz")) { error in
            guard case TaskResolverError.noMatch(let q) = error else {
                XCTFail("expected noMatch, got \(error)"); return
            }
            XCTAssertEqual(q, "zzzz")
        }
    }

    func testThrowsOnMultipleMatches() {
        // Both "Deploy Web" and "Deploy Job" — same length so FuzzyMatch
        // ties them on the query "deploy" and the resolver flags ambiguity.
        let extra = Sample(id: UUID(), name: "Deploy Job")
        let r = TaskResolver(items: samples + [extra],
                             idOf: { $0.id },
                             nameOf: { $0.name })
        XCTAssertThrowsError(try r.resolve("deploy")) { error in
            guard case TaskResolverError.ambiguous(let candidates) = error else {
                XCTFail("expected ambiguous, got \(error)"); return
            }
            XCTAssertEqual(candidates.count, 2)
        }
    }

    func testOldSerialNumbersDoNotResolveTasks() {
        XCTAssertThrowsError(try resolver().resolve("#15"))
        XCTAssertThrowsError(try resolver().resolve("20"))
    }

    func testNumericAndHashNamesStillResolve() throws {
        let numeric = Sample(id: UUID(), name: "20")
        let hash = Sample(id: UUID(), name: "#15")
        let r = TaskResolver(items: samples + [numeric, hash],
                             idOf: { $0.id },
                             nameOf: { $0.name })
        XCTAssertEqual(try r.resolve("20").id, numeric.id)
        XCTAssertEqual(try r.resolve("#15").id, hash.id)
    }
}
