import Foundation
internal import CZlib

// ZIP format constants and little-endian helpers (APPNOTE.TXT 6.3.10).

enum Signature {
    static let localHeader: UInt32 = 0x0403_4B50
    static let centralHeader: UInt32 = 0x0201_4B50
    static let dataDescriptor: UInt32 = 0x0807_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
    static let zip64Locator: UInt32 = 0x0706_4B50
}

enum ExtraField {
    static let zip64: UInt16 = 0x0001
    static let extendedTimestamp: UInt16 = 0x5455 // "UT": Unix mtime, UTC
}

enum Flag {
    static let encrypted: UInt16 = 1 << 0
    static let dataDescriptor: UInt16 = 1 << 3
    static let strongEncryption: UInt16 = 1 << 6
    static let utf8: UInt16 = 1 << 11
}

enum Method {
    static let stored: UInt16 = 0
    static let deflated: UInt16 = 8
}

/// Why reading or writing an archive failed; mapped to a ``ZipStatus`` at the API boundary.
enum ArchiveError: Error, Equatable {
    case corrupt(String)
    case unsupported(String)
    case unsafePath
    case limitExceeded(String)
    case incorrectPassword
    case io(String)

    var status: ZipStatus {
        switch self {
        case .corrupt, .unsupported, .io: return .UnzipFail
        case .unsafePath: return .UnzipUnsafePath
        case .limitExceeded: return .UnzipLimitExceeded
        case .incorrectPassword: return .UnzipIncorrectPassword
        }
    }
}

/// Bounds-checked little-endian reads from a byte array. Every read throws `.corrupt` instead
/// of trapping when the data is too short.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, count: Int? = nil) {
        self.bytes = bytes
        self.offset = start
        self.end = count.map { start + $0 } ?? bytes.count
    }

    var remaining: Int { end - offset }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, n <= remaining else { throw ArchiveError.corrupt("truncated record") }
        offset += n
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ArchiveError.corrupt("truncated record") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ArchiveError.corrupt("truncated record") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ArchiveError.corrupt("truncated record") }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        return v
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw ArchiveError.corrupt("truncated record") }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        return v
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw ArchiveError.corrupt("truncated record") }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
}

extension Array where Element == UInt8 {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}

/// `a + b`, or nil on overflow.
@inline(__always) func checkedAdd(_ a: UInt64, _ b: UInt64) -> UInt64? {
    let (r, o) = a.addingReportingOverflow(b)
    return o ? nil : r
}

/// CRC-32 (the ZIP/zlib polynomial) via the system zlib.
@inline(__always) func crc32Update(_ crc: UInt32, _ base: UnsafeRawPointer, _ count: Int) -> UInt32 {
    UInt32(truncatingIfNeeded: crc32(UInt(crc), base.assumingMemoryBound(to: Bytef.self), UInt32(count)))
}

// MARK: - DOS date and time

struct DOSDateTime: Equatable {
    var time: UInt16
    var date: UInt16

    /// Local broken-down time of `seconds`, clamped to the DOS range 1980...2107.
    init(_ seconds: Int) {
        var clock = time_t(seconds)
        var t = tm()
        guard localtime_r(&clock, &t) != nil else { self.init(time: 0, date: 0x21); return }
        var year = Int(t.tm_year) + 1900
        var (mon, day, hour, min, sec) = (Int(t.tm_mon) + 1, Int(t.tm_mday), Int(t.tm_hour), Int(t.tm_min), Int(t.tm_sec))
        if year < 1980 { (year, mon, day, hour, min, sec) = (1980, 1, 1, 0, 0, 0) }
        if year > 2107 { (year, mon, day, hour, min, sec) = (2107, 12, 31, 23, 59, 58) }
        self.init(time: UInt16(hour << 11 | min << 5 | sec / 2),
                  date: UInt16((year - 1980) << 9 | mon << 5 | day))
    }

    init(time: UInt16, date: UInt16) { self.time = time; self.date = date }

    /// Seconds since the epoch, interpreting the DOS fields as local time.
    var seconds: Int? {
        var t = tm()
        t.tm_sec = Int32((time & 0x1F) * 2)
        t.tm_min = Int32((time >> 5) & 0x3F)
        t.tm_hour = Int32(time >> 11)
        t.tm_mday = Int32(date & 0x1F)
        t.tm_mon = Int32((date >> 5) & 0x0F) - 1
        t.tm_year = Int32(date >> 9) + 80
        t.tm_isdst = -1
        guard t.tm_mday >= 1, t.tm_mon >= 0, t.tm_mon <= 11 else { return nil }
        let s = mktime(&t)
        return s == -1 ? nil : Int(s)
    }
}

// MARK: - Names

enum NameEncoding {
    /// Decodes an entry name. With the UTF-8 flag the bytes must be valid UTF-8 (otherwise
    /// nil). Without it, valid UTF-8 is still taken as UTF-8 (macOS `ditto` and Info-ZIP on
    /// Unix write UTF-8 without setting the flag), and anything else is decoded as IBM code
    /// page 437, the format's original encoding.
    static func decode(_ raw: [UInt8], utf8Flag: Bool) -> String? {
        let utf8 = String(decoding: raw, as: UTF8.self)
        if Array(utf8.utf8) == raw { return utf8 } // valid UTF-8 round-trips exactly
        if utf8Flag { return nil }
        var scalars = String.UnicodeScalarView()
        for b in raw {
            scalars.append(b < 0x80 ? Unicode.Scalar(b) : cp437High[Int(b - 0x80)])
        }
        return String(scalars)
    }

    /// CP437 0x80...0xFF. None of these is `/`, `\`, `.` or NUL, so decoding cannot create
    /// path syntax that the raw bytes did not have.
    private static let cp437High: [Unicode.Scalar] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
            .unicodeScalars)
}
