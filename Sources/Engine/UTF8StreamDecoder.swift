import Foundation

/// Incremental UTF-8 decoder for pipe/file streaming. Foundation's
/// `String(decoding:as:)` treats each call as a complete byte sequence, so a
/// scalar split across two pipe reads becomes replacement characters. This
/// decoder retains only a possibly-incomplete trailing scalar (at most 3 bytes)
/// and emits it once the next chunk arrives.
struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    mutating func decode(_ incoming: Data) -> String {
        guard !incoming.isEmpty else { return "" }
        var combined = pending
        combined.append(incoming)
        pending.removeAll(keepingCapacity: true)

        let bytes = [UInt8](combined)
        let heldCount = Self.incompleteSuffixLength(bytes)
        let emittedCount = bytes.count - heldCount
        if heldCount > 0 {
            pending.append(contentsOf: bytes[emittedCount...])
        }
        guard emittedCount > 0 else { return "" }
        return String(decoding: bytes[..<emittedCount], as: UTF8.self)
    }

    /// Flushes an actually malformed final suffix using normal replacement
    /// semantics. Valid streams normally have no bytes left here.
    mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }

    private static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var start = bytes.count - 1
        let earliest = max(0, bytes.count - 4)
        while start > earliest, isContinuation(bytes[start]) {
            start -= 1
        }

        let lead = bytes[start]
        let expected: Int
        switch lead {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return 0
        }
        let available = bytes.count - start
        guard available < expected,
              bytes[(start + 1)...].allSatisfy(isContinuation) else { return 0 }
        return available
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }
}
