import Foundation
import GRDB
import SQLite3

/// Attributes oversized jobs without materializing their JSON. Reads the whole
/// structure to rule out duplicate ownership fields, including escaped keys.
struct TicketCleanupJobOwner {
    static let fieldLimit = 64 * 1024
    private static let depthLimit = 64
    private static let numberLimit = 256

    static func task(_ db: Database,row: Row,project: Data) -> Data? {
        let revisionValue: DatabaseValue = row["revision"]
        guard row["id_type"] as String == "text",
              let id: Data = row["_envelope_id_bytes"],
              case .int64(let revision) = revisionValue.storage, revision > 0 else {return nil}
        let rowID: Int64 = row["rowid"]
        var handle: OpaquePointer?
        guard sqlite3_blob_open(db.sqliteConnection,"main","records","data",rowID,0,&handle) == SQLITE_OK,
              let handle else {return nil}
        defer {sqlite3_blob_close(handle)}
        var reader = Self(blob:handle,size:sqlite3_blob_bytes(handle))
        return try? reader.owner(id:id,project:project,revision:revision)
    }

    private let blob: OpaquePointer
    private let size: Int32
    private var chunk = [UInt8](repeating:0,count:64 * 1024)
    private var offset: Int32 = 0
    private var index = 0
    private var end = 0
    private struct Unattributable: Error {}

    private init(blob: OpaquePointer,size: Int32) {self.blob = blob;self.size = size}

    private mutating func owner(id: Data,project: Data,revision: Int64) throws -> Data {
        try whitespace()
        try expect(123) // {
        var owner: Data?, keys = Set<String>()
        try members(ending:125) {reader in
            guard let key = try reader.string(capture:true) else {throw Unattributable()}
            try reader.whitespace()
            try reader.expect(58) // :
            try reader.whitespace()
            switch key {
            case "id", "project_id", "task_id":
                guard keys.insert(key).inserted,
                      let value = try reader.string(capture:true), !value.isEmpty else {throw Unattributable()}
                let bytes = Data(value.utf8)
                switch key {
                case "id": guard bytes == id else {throw Unattributable()}
                case "project_id": guard bytes == project else {throw Unattributable()}
                default: owner = bytes
                }
            case "revision":
                guard keys.insert(key).inserted else {throw Unattributable()}
                let number = try reader.number()
                guard try EnvelopeInteger.positiveExact(String(decoding:number,as:UTF8.self)) == revision,
                      let decoded = try JSONSerialization.jsonObject(with:Data(number),options:[.fragmentsAllowed]) as? NSNumber,
                      try EnvelopeInteger.positiveExact(decoded.stringValue) == revision else {throw Unattributable()}
            default:
                try reader.skipValue(depth:1)
            }
        }
        try whitespace()
        guard try peek() == nil, keys.count == 4, let owner else {throw Unattributable()}
        return owner
    }

    private mutating func peek() throws -> UInt8? {
        if index == end {
            guard offset < size else {return nil}
            let count = min(Int(size - offset),chunk.count)
            guard chunk.withUnsafeMutableBytes({sqlite3_blob_read(blob,$0.baseAddress,Int32(count),offset)}) == SQLITE_OK else {
                throw Unattributable()
            }
            // End on a UTF-8 boundary. The next read repeats at most three bytes.
            end = count
            if offset + Int32(count) < size {
                var start = count - 1
                while start > 0, chunk[start] & 0xc0 == 0x80 {start -= 1}
                let first = chunk[start]
                let width = first < 0x80 ? 1 : first < 0xe0 ? 2 : first < 0xf0 ? 3 : 4
                if count - start < width {end = start}
            }
            guard end > 0, autoreleasepool(invoking:{String(bytes:chunk[..<end],encoding:.utf8) != nil}) else {throw Unattributable()}
            offset += Int32(end)
            index = 0
        }
        return chunk[index]
    }

    private mutating func take(_ byte: UInt8) throws -> Bool {
        guard try peek() == byte else {return false}
        index += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard try take(byte) else {throw Unattributable()}
    }

    private mutating func whitespace() throws {
        while let byte = try peek(), byte == 32 || byte == 9 || byte == 10 || byte == 13 {index += 1}
    }

    private mutating func members(ending: UInt8,_ member: (inout Self) throws -> Void) throws {
        try whitespace()
        if try take(ending) {return}
        repeat {
            try whitespace()
            try member(&self)
            try whitespace()
            if try take(ending) {return}
            try expect(44) // ,
        } while true
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth <= Self.depthLimit else {throw Unattributable()}
        switch try peek() {
        case 34: _ = try string(capture:false)
        case 123: // {
            index += 1
            try members(ending:125) {reader in
                _ = try reader.string(capture:false)
                try reader.whitespace()
                try reader.expect(58)
                try reader.whitespace()
                try reader.skipValue(depth:depth + 1)
            }
        case 91: // [
            index += 1
            try members(ending:93) {try $0.skipValue(depth:depth + 1)}
        case 116: for byte in "true".utf8 {try expect(byte)}
        case 102: for byte in "false".utf8 {try expect(byte)}
        case 110: for byte in "null".utf8 {try expect(byte)}
        default: _ = try number()
        }
    }

    private mutating func string(capture: Bool) throws -> String? {
        try expect(34)
        var token: [UInt8] = capture ? [34] : []
        while let byte = try peek() {
            let start = index
            switch byte {
            case 34:
                index += 1
                guard capture else {return nil}
                guard token.count < Self.fieldLimit else {throw Unattributable()}
                token.append(34)
                return try autoreleasepool {
                    try JSONSerialization.jsonObject(with:Data(token),options:[.fragmentsAllowed]) as? String
                }
            case 92: // One escape can straddle a chunk, so capture it as it is read.
                index += 1
                if capture {token.append(92)}
                let escaped = try stringByte(capture:capture,into:&token)
                switch escaped {
                case 34, 47, 92, 98, 102, 110, 114, 116: break
                case 117:
                    let unit = try hexUnit(capture:capture,into:&token)
                    if (0xd800...0xdbff).contains(unit) {
                        guard try stringByte(capture:capture,into:&token) == 92,
                              try stringByte(capture:capture,into:&token) == 117,
                              try (0xdc00...0xdfff).contains(hexUnit(capture:capture,into:&token)) else {throw Unattributable()}
                    } else if (0xdc00...0xdfff).contains(unit) {throw Unattributable()}
                default: throw Unattributable()
                }
            case 0..<32: throw Unattributable()
            default:
                repeat {index += 1} while index < end && chunk[index] >= 32 && chunk[index] != 34 && chunk[index] != 92
                if capture {
                    guard token.count + index - start <= Self.fieldLimit else {throw Unattributable()}
                    token.append(contentsOf:chunk[start..<index])
                }
            }
            guard token.count <= Self.fieldLimit else {throw Unattributable()}
        }
        throw Unattributable()
    }

    private mutating func stringByte(capture: Bool,into token: inout [UInt8]) throws -> UInt8 {
        guard let byte = try peek() else {throw Unattributable()}
        index += 1
        if capture {token.append(byte)}
        return byte
    }

    private mutating func hexUnit(capture: Bool,into token: inout [UInt8]) throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try stringByte(capture:capture,into:&token)
            let digit: UInt8
            switch byte {
            case 48...57: digit = byte - 48
            case 65...70: digit = byte - 55
            case 97...102: digit = byte - 87
            default: throw Unattributable()
            }
            value = (value << 4) + Int(digit)
        }
        return value
    }

    private mutating func number() throws -> [UInt8] {
        var token: [UInt8] = []
        if try take(45) {token.append(45)}
        if try take(48) {token.append(48)} else {try digits(into:&token)}
        if try take(46) {token.append(46);try digits(into:&token)}
        if try take(101) || take(69) {
            token.append(101)
            if try take(45) {token.append(45)} else if try take(43) {token.append(43)}
            try digits(into:&token)
        }
        return token
    }

    private mutating func digits(into token: inout [UInt8]) throws {
        let start = token.count
        while let byte = try peek(), (48...57).contains(byte) {
            guard token.count < Self.numberLimit else {throw Unattributable()}
            token.append(byte)
            index += 1
        }
        guard token.count > start else {throw Unattributable()}
    }
}
