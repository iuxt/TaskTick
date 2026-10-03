import Foundation

/// Streaming byte-level ANSI removal before UTF-8 decoding. State survives
/// pipe boundaries, including CSI, OSC (BEL or ESC-backslash), and scalars.
struct ProcessOutputDecoder: Sendable {
    private enum State: Sendable { case text, escape, csi, osc, oscEscape, charset }
    private var state = State.text
    private var utf8 = UTF8StreamDecoder()

    mutating func decode(_ data: Data) -> String {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b { state = .escape }
                else if byte >= 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
                    output.append(byte)
                }
            case .escape:
                switch byte {
                case 0x5b: state = .csi
                case 0x5d: state = .osc
                case 0x28, 0x29: state = .charset
                case 0x1b: break
                default: state = .text
                }
            case .csi:
                if (0x40...0x7e).contains(byte) { state = .text }
                else if byte == 0x1b { state = .escape }
            case .osc:
                if byte == 0x07 { state = .text }
                else if byte == 0x1b { state = .oscEscape }
            case .oscEscape:
                if byte == 0x5c || byte == 0x07 { state = .text }
                else if byte != 0x1b { state = .osc }
            case .charset:
                state = .text
            }
        }
        return utf8.decode(output)
    }

    mutating func finish() -> String {
        state = .text
        return utf8.finish()
    }
}
