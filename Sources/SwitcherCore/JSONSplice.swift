import Foundation

/// Replaces one top-level value in a JSON document without re-encoding the rest.
///
/// Parsing `~/.claude.json` and writing it back (what `jq` does) loses key order,
/// turns `1.0` into `1` and re-escapes every path.  Finding the value's byte span
/// and replacing only those bytes keeps every other byte of the file as it was.
enum JSONSplice {
    enum SpliceError: Error, Equatable, CustomStringConvertible {
        case notAnObject
        case keyNotFound(String)
        case malformed(String)

        public var description: String {
            switch self {
            case .notAnObject: return "the document is not a JSON object"
            case .keyNotFound(let key): return "no top-level \"\(key)\" key"
            case .malformed(let why): return "could not read the JSON: \(why)"
            }
        }
    }

    /// Byte range of the value belonging to a top-level key, brace to brace.
    static func valueRange(of key: String, in data: Data) throws -> Range<Int> {
        let bytes = [UInt8](data)
        var index = skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
            throw SpliceError.notAnObject
        }
        index += 1
        index = skipWhitespace(bytes, from: index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            throw SpliceError.keyNotFound(key)
        }

        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\"") else {
                throw SpliceError.malformed("expected a key at byte \(index)")
            }
            let keyEnd = try endOfString(bytes, from: index)
            let name = try decodeString(bytes, from: index, to: keyEnd)

            index = skipWhitespace(bytes, from: keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw SpliceError.malformed("expected \":\" after \"\(name)\"")
            }
            index = skipWhitespace(bytes, from: index + 1)
            let valueStart = index
            let valueEnd = try endOfValue(bytes, from: index)
            if name == key { return valueStart..<valueEnd }

            index = skipWhitespace(bytes, from: valueEnd)
            guard index < bytes.count else { throw SpliceError.malformed("truncated document") }
            if bytes[index] == UInt8(ascii: "}") { throw SpliceError.keyNotFound(key) }
            guard bytes[index] == UInt8(ascii: ",") else {
                throw SpliceError.malformed("expected \",\" or \"}\" at byte \(index)")
            }
            index = skipWhitespace(bytes, from: index + 1)
        }
        throw SpliceError.keyNotFound(key)
    }

    /// The document with `key`'s value replaced by `value`, everything else byte for byte.
    static func replace(_ key: String, in data: Data, with value: Data) throws -> Data {
        let range = try valueRange(of: key, in: data)
        var out = Data()
        out.reserveCapacity(data.count + value.count)
        out.append(data.prefix(range.lowerBound))
        out.append(value)
        out.append(data.suffix(from: range.upperBound))
        return out
    }
}

// MARK: - Scanning

extension JSONSplice {
    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d: index += 1
            default: return index
            }
        }
        return index
    }

    /// One past the closing quote of the string starting at `start`.
    private static func endOfString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 2          // an escape can hide a quote
                continue
            }
            if byte == UInt8(ascii: "\"") { return index + 1 }
            index += 1
        }
        throw SpliceError.malformed("unterminated string at byte \(start)")
    }

    private static func decodeString(_ bytes: [UInt8], from start: Int, to end: Int) throws -> String {
        let slice = Data(bytes[start..<end])
        guard let any = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]),
              let text = any as? String else {
            throw SpliceError.malformed("bad key string at byte \(start)")
        }
        return text
    }

    /// One past the last byte of the value starting at `start`.  Brackets inside strings
    /// do not count, so a `}` in an email address cannot end an object early.
    private static func endOfValue(_ bytes: [UInt8], from start: Int) throws -> Int {
        guard start < bytes.count else { throw SpliceError.malformed("value expected at the end") }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return try endOfString(bytes, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    index = try endOfString(bytes, from: index)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            throw SpliceError.malformed("unbalanced brackets from byte \(start)")
        default:
            // A number, true, false or null ends at the next structural byte or whitespace.
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     0x20, 0x09, 0x0a, 0x0d:
                    return index
                default:
                    index += 1
                }
            }
            return index
        }
    }
}
