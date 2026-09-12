import Foundation

/// A parsed PDF object (the subset needed to inspect page trees and outlines).
public indirect enum PDFObject: Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    /// Decoded bytes of a literal or hex string.
    case string([UInt8])
    case name(String)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    case reference(Int, Int)
    /// A stream: its dictionary and the byte range of its (raw, unfiltered) data in the file.
    case stream([String: PDFObject], dataRange: Range<Int>)

    public var number: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .real(let r): return r
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .real(let r): return r == r.rounded() ? Int(r) : nil
        default: return nil
        }
    }
    public var dictionaryValue: [String: PDFObject]? {
        switch self {
        case .dictionary(let d): return d
        case .stream(let d, _): return d
        default: return nil
        }
    }
    public var arrayValue: [PDFObject]? { if case .array(let a) = self { return a } else { return nil } }
    public var nameValue: String? { if case .name(let n) = self { return n } else { return nil } }
    public var stringBytes: [UInt8]? { if case .string(let s) = self { return s } else { return nil } }
}

/// Tokenizer + recursive-descent parser for uncompressed PDF syntax.
struct PDFObjectParser {
    let bytes: [UInt8]
    var cursor: Int

    init(bytes: [UInt8], cursor: Int = 0) { self.bytes = bytes; self.cursor = cursor }

    enum Failure: Error { case unexpectedEnd, unexpectedToken(String, at: Int) }

    static func isDelimiter(_ b: UInt8) -> Bool {
        b == 0x28 || b == 0x29 || b == 0x3C || b == 0x3E || b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D || b == 0x2F || b == 0x25
    }
    static func isRegular(_ b: UInt8) -> Bool { !PDFXrefChecker.isWhitespace(b) && !isDelimiter(b) }

    mutating func skipWhitespaceAndComments() {
        while cursor < bytes.count {
            if PDFXrefChecker.isWhitespace(bytes[cursor]) { cursor += 1; continue }
            if bytes[cursor] == 0x25 { // % comment to end of line
                while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D { cursor += 1 }
                continue
            }
            break
        }
    }

    mutating func readKeyword() -> String {
        let start = cursor
        while cursor < bytes.count, Self.isRegular(bytes[cursor]) { cursor += 1 }
        return String(decoding: bytes[start..<cursor], as: UTF8.self)
    }

    /// Parses `N G obj <object>` at the cursor and returns (N, G, object).
    mutating func parseIndirectObject() throws -> (Int, Int, PDFObject) {
        skipWhitespaceAndComments()
        guard let n = PDFXrefChecker.readInt(bytes, &cursor) else { throw Failure.unexpectedToken("object number", at: cursor) }
        skipWhitespaceAndComments()
        guard let g = PDFXrefChecker.readInt(bytes, &cursor) else { throw Failure.unexpectedToken("generation", at: cursor) }
        skipWhitespaceAndComments()
        guard readKeyword() == "obj" else { throw Failure.unexpectedToken("obj", at: cursor) }
        let value = try parseObject()
        return (n, g, value)
    }

    mutating func parseObject() throws -> PDFObject {
        skipWhitespaceAndComments()
        guard cursor < bytes.count else { throw Failure.unexpectedEnd }
        let b = bytes[cursor]
        switch b {
        case 0x2F: // /Name
            cursor += 1
            let start = cursor
            while cursor < bytes.count, Self.isRegular(bytes[cursor]) { cursor += 1 }
            return .name(decodeName(Array(bytes[start..<cursor])))
        case 0x28: // (string)
            return .string(try parseLiteralString())
        case 0x3C: // << dict >> or <hex>
            if cursor + 1 < bytes.count, bytes[cursor + 1] == 0x3C { return try parseDictionaryOrStream() }
            return .string(try parseHexString())
        case 0x5B: // [ array ]
            cursor += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespaceAndComments()
                guard cursor < bytes.count else { throw Failure.unexpectedEnd }
                if bytes[cursor] == 0x5D { cursor += 1; return .array(items) }
                items.append(try parseObjectOrReference())
            }
        case 0x5D, 0x3E, 0x29, 0x7B, 0x7D:
            throw Failure.unexpectedToken(String(UnicodeScalar(b)), at: cursor)
        default:
            if (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2D || b == 0x2E {
                return try parseNumber()
            }
            let kw = readKeyword()
            switch kw {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .null
            case "": throw Failure.unexpectedToken("byte \(b)", at: cursor)
            default: throw Failure.unexpectedToken(kw, at: cursor)
            }
        }
    }

    /// Like `parseObject` but recognizes `N G R` references (valid inside arrays and dictionaries).
    mutating func parseObjectOrReference() throws -> PDFObject {
        skipWhitespaceAndComments()
        let save = cursor
        if cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            var c = cursor
            if let n = PDFXrefChecker.readInt(bytes, &c) {
                var c2 = c
                PDFXrefChecker.skipWhitespace(bytes, &c2)
                if c2 > c, let g = PDFXrefChecker.readInt(bytes, &c2) {
                    var c3 = c2
                    PDFXrefChecker.skipWhitespace(bytes, &c3)
                    if c3 > c2, c3 < bytes.count, bytes[c3] == 0x52, (c3 + 1 == bytes.count || !Self.isRegular(bytes[c3 + 1])) {
                        cursor = c3 + 1
                        return .reference(n, g)
                    }
                }
            }
            cursor = save
        }
        return try parseObject()
    }

    mutating func parseNumber() throws -> PDFObject {
        let start = cursor
        while cursor < bytes.count, Self.isRegular(bytes[cursor]) { cursor += 1 }
        let text = String(decoding: bytes[start..<cursor], as: UTF8.self)
        if let i = Int(text) { return .integer(i) }
        if let d = Double(text) { return .real(d) }
        throw Failure.unexpectedToken(text, at: start)
    }

    mutating func parseDictionaryOrStream() throws -> PDFObject {
        cursor += 2
        var dict: [String: PDFObject] = [:]
        while true {
            skipWhitespaceAndComments()
            guard cursor < bytes.count else { throw Failure.unexpectedEnd }
            if bytes[cursor] == 0x3E {
                guard cursor + 1 < bytes.count, bytes[cursor + 1] == 0x3E else { throw Failure.unexpectedToken(">", at: cursor) }
                cursor += 2
                break
            }
            guard bytes[cursor] == 0x2F else { throw Failure.unexpectedToken("dictionary key", at: cursor) }
            guard case .name(let key) = try parseObject() else { throw Failure.unexpectedToken("name", at: cursor) }
            dict[key] = try parseObjectOrReference()
        }
        // Stream?
        let save = cursor
        skipWhitespaceAndComments()
        if PDFXrefChecker.matches(bytes, at: cursor, Array("stream".utf8)) {
            cursor += 6
            if cursor < bytes.count, bytes[cursor] == 0x0D { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 0x0A { cursor += 1 }
            let dataStart = cursor
            var dataEnd: Int
            if let len = dict["Length"]?.intValue, len >= 0, dataStart + len <= bytes.count {
                dataEnd = dataStart + len
            } else if let r = PDFXrefChecker.range(of: Array("endstream".utf8), in: bytes, from: dataStart) {
                dataEnd = r.lowerBound
                if dataEnd > dataStart, bytes[dataEnd - 1] == 0x0A { dataEnd -= 1 }
                if dataEnd > dataStart, bytes[dataEnd - 1] == 0x0D { dataEnd -= 1 }
            } else {
                throw Failure.unexpectedEnd
            }
            cursor = dataEnd
            skipWhitespaceAndComments()
            guard PDFXrefChecker.matches(bytes, at: cursor, Array("endstream".utf8)) else {
                throw Failure.unexpectedToken("endstream", at: cursor)
            }
            cursor += 9
            return .stream(dict, dataRange: dataStart..<dataEnd)
        }
        cursor = save
        return .dictionary(dict)
    }

    mutating func parseLiteralString() throws -> [UInt8] {
        cursor += 1
        var depth = 1
        var out: [UInt8] = []
        while cursor < bytes.count {
            let b = bytes[cursor]; cursor += 1
            switch b {
            case 0x5C: // backslash
                guard cursor < bytes.count else { throw Failure.unexpectedEnd }
                let e = bytes[cursor]; cursor += 1
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x0A: break
                case 0x0D: if cursor < bytes.count, bytes[cursor] == 0x0A { cursor += 1 }
                case 0x30...0x37:
                    var v = Int(e - 0x30), n = 1
                    while n < 3, cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x37 {
                        v = v * 8 + Int(bytes[cursor] - 0x30); cursor += 1; n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default: out.append(e)
                }
            case 0x28: depth += 1; out.append(b)
            case 0x29:
                depth -= 1
                if depth == 0 { return out }
                out.append(b)
            default: out.append(b)
            }
        }
        throw Failure.unexpectedEnd
    }

    mutating func parseHexString() throws -> [UInt8] {
        cursor += 1
        var out: [UInt8] = []
        var pending: UInt8? = nil
        while cursor < bytes.count {
            let b = bytes[cursor]; cursor += 1
            if b == 0x3E {
                if let p = pending { out.append(p << 4) }
                return out
            }
            if PDFXrefChecker.isWhitespace(b) { continue }
            guard let v = hexValue(b) else { throw Failure.unexpectedToken("hex digit", at: cursor - 1) }
            if let p = pending { out.append(p << 4 | v); pending = nil } else { pending = v }
        }
        throw Failure.unexpectedEnd
    }

    func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    func decodeName(_ raw: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < raw.count {
            if raw[i] == 0x23, i + 2 < raw.count, let h = hexValue(raw[i + 1]), let l = hexValue(raw[i + 2]) {
                out.append(h << 4 | l); i += 3
            } else { out.append(raw[i]); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Decodes PDF text-string bytes: UTF-16BE with BOM, else PDFDocEncoding treated as Latin-1.
enum PDFTextString {
    static func decode(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}
