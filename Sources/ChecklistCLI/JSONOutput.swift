import Foundation

/// Keep CLI strings RFC 8259 compliant even if an encoder emits literal controls.
/// Formatting whitespace outside strings and existing escapes stay byte-for-byte intact.
enum JSONOutput {
    static func escapingStringControls(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        var inString = false
        var escaped = false
        let hex = Array("0123456789abcdef".utf8)
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                } else if byte < 0x20 {
                    output.append(contentsOf: [0x5c, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0xf)]])
                    continue
                }
            } else if byte == 0x22 {
                inString = true
            }
            output.append(byte)
        }
        return output
    }
}
