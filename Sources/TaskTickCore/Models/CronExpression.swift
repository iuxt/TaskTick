import Foundation

/// Cron expression parser supporting standard 5-field format:
/// minute hour dayOfMonth month dayOfWeek
/// plus an extended 6-field format with a leading seconds field (Quartz style):
/// second minute hour dayOfMonth month dayOfWeek — see issue #38.
public struct CronExpression: Sendable {
    /// nil for 5-field expressions, which fire at second 0 of each matching
    /// minute (classic cron behavior, unchanged).
    public let seconds: CronField?
    public let minute: CronField
    public let hour: CronField
    public let dayOfMonth: CronField
    public let month: CronField
    public let dayOfWeek: CronField

    public let raw: String
    private let dayOfMonthUsesWildcard: Bool
    private let dayOfWeekUsesWildcard: Bool

    public enum CronField: Sendable, Equatable {
        case any                          // *
        case step(Int)                    // */N
        case value(Int)                   // N
        case range(Int, Int)              // N-M
        case rangeStep(Int, Int, Int)     // N-M/S
        case list([CronFieldEntry])       // N,M,O or combined

        public enum CronFieldEntry: Sendable, Equatable {
            case value(Int)
            case range(Int, Int)
            case step(Int)
            case rangeStep(Int, Int, Int)
        }
    }

    public enum ParseError: Error, LocalizedError {
        case invalidFormat(String)
        case invalidField(String, String)
        case valueOutOfRange(field: String, value: Int, range: ClosedRange<Int>)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let expr):
                return "无效的 Cron 表达式格式: \(expr)，需要 5 或 6 个字段"
            case .invalidField(let field, let value):
                return "无效的字段值 '\(value)' (字段: \(field))"
            case .valueOutOfRange(let field, let value, let range):
                return "值 \(value) 超出范围 \(range) (字段: \(field))"
            }
        }
    }

    public static let fieldRanges: [(name: String, range: ClosedRange<Int>)] = [
        ("minute", 0...59),
        ("hour", 0...23),
        ("dayOfMonth", 1...31),
        ("month", 1...12),
        // Both 0 and 7 mean Sunday in traditional crontab syntax.
        ("dayOfWeek", 0...7)
    ]

    public init(parsing expression: String) throws {
        self.raw = expression.trimmingCharacters(in: .whitespaces)
        var parts = self.raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        switch parts.count {
        case 5:
            self.seconds = nil
        case 6:
            self.seconds = try Self.parseField(parts[0], name: "second", range: 0...59)
            parts.removeFirst()
        default:
            throw ParseError.invalidFormat(expression)
        }

        self.dayOfMonthUsesWildcard = parts[2].hasPrefix("*")
        self.dayOfWeekUsesWildcard = parts[4].hasPrefix("*")
        self.minute = try Self.parseField(parts[0], fieldIndex: 0)
        self.hour = try Self.parseField(parts[1], fieldIndex: 1)
        self.dayOfMonth = try Self.parseField(parts[2], fieldIndex: 2)
        self.month = try Self.parseField(parts[3], fieldIndex: 3)
        self.dayOfWeek = try Self.parseField(parts[4], fieldIndex: 4)
    }

    private static func parseField(_ value: String, fieldIndex: Int) throws -> CronField {
        let (name, range) = fieldRanges[fieldIndex]
        return try parseField(value, name: name, range: range)
    }

    private static func parseField(_ value: String, name: String, range: ClosedRange<Int>) throws -> CronField {
        if value == "*" {
            return .any
        }

        if value.contains(",") {
            let entries = try value.split(separator: ",").map { part in
                try parseEntry(String(part), wholeValue: value, name: name, range: range)
            }
            return .list(entries)
        }

        switch try parseEntry(value, wholeValue: value, name: name, range: range) {
        case .value(let v): return .value(v)
        case .range(let low, let high): return .range(low, high)
        case .step(let step): return .step(step)
        case .rangeStep(let low, let high, let step): return .rangeStep(low, high, step)
        }
    }

    private static func parseEntry(
        _ token: String,
        wholeValue: String,
        name: String,
        range: ClosedRange<Int>
    ) throws -> CronField.CronFieldEntry {
        let slashParts = token.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard slashParts.count <= 2 else { throw ParseError.invalidField(name, wholeValue) }
        let base = slashParts[0]
        let step: Int?
        if slashParts.count == 2 {
            guard let parsed = Int(slashParts[1]), parsed > 0 else {
                throw ParseError.invalidField(name, wholeValue)
            }
            step = parsed
        } else {
            step = nil
        }

        if base == "*" {
            guard let step else { throw ParseError.invalidField(name, wholeValue) }
            return .step(step)
        }

        if base.contains("-") {
            let bounds = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard bounds.count == 2 else { throw ParseError.invalidField(name, wholeValue) }
            let low = try parseValue(bounds[0], wholeValue: wholeValue, name: name, range: range)
            let high = try parseValue(bounds[1], wholeValue: wholeValue, name: name, range: range)
            guard low <= high else { throw ParseError.invalidField(name, wholeValue) }
            return step.map { .rangeStep(low, high, $0) } ?? .range(low, high)
        }

        let value = try parseValue(base, wholeValue: wholeValue, name: name, range: range)
        if let step {
            return .rangeStep(value, range.upperBound, step)
        }
        return .value(value)
    }

    private static func parseValue(
        _ token: String,
        wholeValue: String,
        name: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        let upper = token.uppercased()
        let named: Int? = switch name {
        case "month": [
            "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
            "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
        ][upper]
        case "dayOfWeek": [
            "SUN": 0, "MON": 1, "TUE": 2, "WED": 3,
            "THU": 4, "FRI": 5, "SAT": 6,
        ][upper]
        default: nil
        }
        guard let value = named ?? Int(token) else {
            throw ParseError.invalidField(name, wholeValue)
        }
        try validateRange(value, field: name, range: range)
        return value
    }

    private static func validateRange(_ value: Int, field: String, range: ClosedRange<Int>) throws {
        guard range.contains(value) else {
            throw ParseError.valueOutOfRange(field: field, value: value, range: range)
        }
    }

    /// Calculate the next fire date after the given date.
    /// `calendar` controls the time zone the cron fields are interpreted in;
    /// defaults to the system calendar (issue #41).
    public func nextFireDate(after date: Date = Date(), calendar: Calendar = Calendar.current) -> Date? {
        // Keep the instant's occurrence of a repeated DST minute. Rebuilding
        // civil components can select the first occurrence and move backwards.
        guard let currentMinute = calendar.dateInterval(of: .minute, for: date) else { return nil }

        // 6-field expressions: the current minute may still contain a matching
        // second — check it before falling into the minute-by-minute scan.
        if let secondsField = seconds {
            let comps = calendar.dateComponents(
                [.minute, .hour, .day, .month, .weekday, .second], from: date)
            if let m = comps.minute, let h = comps.hour, let d = comps.day,
               let mo = comps.month, let wd = comps.weekday, let s = comps.second,
               minuteLevelMatches(m: m, h: h, d: d, mo: mo, cronWeekday: wd - 1),
               let nextSecond = ((s + 1)..<60).first(where: { matches(field: secondsField, value: $0) }) {
                return currentMinute.start.addingTimeInterval(TimeInterval(nextSecond))
            }
        }

        let firstCandidate = currentMinute.end

        // Search up to 4 years ahead
        guard let limit = calendar.date(byAdding: .year, value: 4, to: date) else { return nil }

        // Rejecting a syntactically valid but impossible expression (for example
        // February 31) used to scan every minute for four years: ~2.1 million
        // Calendar operations on the main actor. Walk civil days first, and only
        // inspect minutes on a day whose month/day fields can actually match.
        // This bounds the impossible-date path to ~1,461 cheap iterations while
        // preserving Calendar's DST handling inside candidate days.
        var day = calendar.startOfDay(for: firstCandidate)
        while day < limit {
            let dayComps = calendar.dateComponents([.day, .month, .weekday], from: day)
            guard let d = dayComps.day, let mo = dayComps.month,
                  let wd = dayComps.weekday else { return nil }

            if dayLevelMatches(d: d, mo: mo, cronWeekday: wd - 1) {
                var candidate = max(firstCandidate, day)
                while calendar.isDate(candidate, inSameDayAs: day), candidate < limit {
                    let time = calendar.dateComponents([.minute, .hour], from: candidate)
                    guard let m = time.minute, let h = time.hour else { return nil }
                    if matches(field: hour, value: h), matches(field: minute, value: m) {
                        guard let secondsField = seconds else {
                            return candidate
                        }
                        if let s = (0..<60).first(where: { matches(field: secondsField, value: $0) }) {
                            return candidate.addingTimeInterval(TimeInterval(s))
                        }
                    }
                    guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                        return nil
                    }
                    candidate = next
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }

        return nil
    }

    /// Do the five minute-level fields match the given instant?
    /// `cronWeekday` uses cron numbering (0=Sunday..6=Saturday); Calendar's
    /// `.weekday` is 1=Sunday..7=Saturday, so callers pass `weekday - 1`.
    private func minuteLevelMatches(m: Int, h: Int, d: Int, mo: Int, cronWeekday: Int) -> Bool {
        dayLevelMatches(d: d, mo: mo, cronWeekday: cronWeekday) &&
        matches(field: hour, value: h) &&
        matches(field: minute, value: m)
    }

    private func dayLevelMatches(d: Int, mo: Int, cronWeekday: Int) -> Bool {
        let domMatches = matches(field: dayOfMonth, value: d, minimum: 1)
        let dowMatches = matches(field: dayOfWeek, value: cronWeekday)
            || (cronWeekday == 0 && matches(field: dayOfWeek, value: 7))
        // crontab combines restricted day fields with OR. A wildcard (including
        // */N) in either field instead requires both fields to match.
        let dayMatches = dayOfMonthUsesWildcard || dayOfWeekUsesWildcard
            ? domMatches && dowMatches : domMatches || dowMatches
        return matches(field: month, value: mo, minimum: 1) && dayMatches
    }

    private func matches(field: CronField, value: Int, minimum: Int = 0) -> Bool {
        switch field {
        case .any:
            return true
        case .step(let step):
            return (value - minimum) % step == 0
        case .value(let v):
            return value == v
        case .range(let low, let high):
            return value >= low && value <= high
        case .rangeStep(let low, let high, let step):
            return value >= low && value <= high && (value - low) % step == 0
        case .list(let entries):
            return entries.contains { entry in
                switch entry {
                case .value(let v): return value == v
                case .range(let low, let high): return value >= low && value <= high
                case .step(let step): return (value - minimum) % step == 0
                case .rangeStep(let low, let high, let step):
                    return value >= low && value <= high && (value - low) % step == 0
                }
            }
        }
    }

    /// Human-readable description of the expression
    public var humanReadable: String {
        switch raw {
        case "* * * * *": return L10n.tr("cron.human.every_minute")
        case "0 * * * *": return L10n.tr("cron.human.every_hour")
        case "0 0 * * *": return L10n.tr("cron.human.daily_midnight")
        case "0 0 * * 0": return L10n.tr("cron.human.weekly_sunday")
        case "0 0 1 * *": return L10n.tr("cron.human.monthly_first")
        default: return raw
        }
    }
}
