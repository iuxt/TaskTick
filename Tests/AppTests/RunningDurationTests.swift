import Foundation
import Testing
@testable import TaskTickApp

@Suite("Running Duration Tests")
struct RunningDurationTests {
    @Test("Uses localized abbreviated units")
    func localizedUnits() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(RunningDuration.format(
            since: now.addingTimeInterval(-30),
            now: now,
            locale: Locale(identifier: "zh-Hans")
        ) == "30秒")
        #expect(RunningDuration.format(
            since: now.addingTimeInterval(-125),
            now: now,
            locale: Locale(identifier: "zh-Hans")
        ) == "2分钟5秒")
        #expect(RunningDuration.format(
            since: now.addingTimeInterval(-3_725),
            now: now,
            locale: Locale(identifier: "en")
        ) == "1h 2m")
    }

    @Test("Clamps future start times to zero")
    func futureStartTime() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(RunningDuration.format(
            since: now.addingTimeInterval(10),
            now: now,
            locale: Locale(identifier: "zh-Hans")
        ) == "0秒")
    }
}
