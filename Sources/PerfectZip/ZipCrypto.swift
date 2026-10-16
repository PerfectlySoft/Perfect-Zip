/// Traditional PKWARE ("ZipCrypto") decryption, APPNOTE.TXT section 6.1. Read-only: the
/// cipher is broken (known-plaintext attacks recover the keys), so PerfectZip does not write it.
struct ZipCrypto {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    /// Size of the encryption header that precedes the (compressed) data.
    static let headerSize = 12

    init(password: [UInt8]) {
        for b in password { update(b) }
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    @inline(__always) private static func crc(_ crc: UInt32, _ b: UInt8) -> UInt32 {
        table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
    }

    @inline(__always) private mutating func update(_ b: UInt8) {
        k0 = Self.crc(k0, b)
        k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
        k2 = Self.crc(k2, UInt8(k1 >> 24))
    }

    @inline(__always) mutating func decrypt(_ c: UInt8) -> UInt8 {
        let t = (k2 | 2) & 0xFFFF
        let p = c ^ UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
        update(p)
        return p
    }

    mutating func decrypt(_ buffer: UnsafeMutableRawBufferPointer) {
        for i in buffer.indices { buffer[i] = decrypt(buffer[i]) }
    }

    /// Decrypts the 12-byte header and returns its last byte, which must equal the high byte
    /// of the CRC (or of the DOS time, when the entry uses a data descriptor).
    mutating func checkByte(header: [UInt8]) -> UInt8 {
        var last: UInt8 = 0
        for b in header { last = decrypt(b) }
        return last
    }
}
