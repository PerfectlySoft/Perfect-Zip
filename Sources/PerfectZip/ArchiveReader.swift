import Foundation
internal import CZlib

/// One entry of the central directory, after its local header has been cross-checked.
struct ArchiveEntry {
    var rawName: [UInt8]
    /// nil when the UTF-8 flag is set but the bytes are not valid UTF-8.
    var name: String?
    var versionMadeBy: UInt16
    var flags: UInt16
    var method: UInt16
    var dosTime: DOSDateTime
    var crc: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localHeaderOffset: UInt64
    var externalAttributes: UInt32
    /// Modification time from the extended-timestamp ("UT") extra field, in UTC.
    var unixModificationTime: Int?
    /// Offset of the first byte after the local header (the encryption header or the data).
    var dataOffset: UInt64 = 0
    /// Offset one past the end of the entry, including any data descriptor.
    var endOffset: UInt64 = 0

    var isEncrypted: Bool { flags & Flag.encrypted != 0 }
    var hasDataDescriptor: Bool { flags & Flag.dataDescriptor != 0 }
    var isDirectory: Bool { rawName.last == UInt8(ascii: "/") || rawName.last == UInt8(ascii: "\\") }
    /// Unix `st_mode`, when the archive was made on Unix or macOS.
    var unixMode: UInt32? {
        let host = versionMadeBy >> 8
        return host == 3 || host == 19 ? externalAttributes >> 16 : nil
    }
    var modificationTime: Int? { unixModificationTime ?? dosTime.seconds }
}

/// Reads a zip archive from a file descriptor with `pread`, so nothing is mapped or loaded
/// whole except the central directory (whose size is bounded by the file's).
///
/// Every length and offset read from the file is checked against the file size and against
/// the region it must lie in, using overflow-checked arithmetic, before it is used.
final class ArchiveReader {
    let fd: Int32
    let fileSize: UInt64
    static let bufferSize = 64 * 1024

    /// Below this declared size an entry's (or the whole archive's) compression ratio is not
    /// checked: tiny files of repeated bytes legitimately compress very well.
    static let ratioCheckFloor: UInt64 = 1 << 20

    init(path: String) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError.io("open") }
        var st = stat()
        guard fstat(fd, &st) == 0, UInt32(st.st_mode) & FileType.mask == FileType.regular else {
            closeFD(fd)
            throw ArchiveError.io("not a regular file")
        }
        fileSize = UInt64(st.st_size)
    }

    deinit { closeFD(fd) }

    // MARK: Raw reads

    func read(at offset: UInt64, into base: UnsafeMutableRawPointer, count: Int) throws {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw ArchiveError.corrupt("read past end of file")
        }
        var done = 0
        while done < count {
            let n = pread(fd, base + done, count - done, off_t(offset + UInt64(done)))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ArchiveError.io("read") }
            done += n
        }
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try read(at: offset, into: $0.baseAddress!, count: count) }
        return bytes
    }

    // MARK: Directory

    /// Parses and validates the whole archive structure: end records, central directory,
    /// every local header, overlap between entries, and the zip-bomb limits.
    func entries(limits: ZipLimits) throws -> [ArchiveEntry] {
        let (cdOffset, cdSize, expectedCount, isZip64) = try locateCentralDirectory()
        guard cdSize <= UInt64(Int.max) else { throw ArchiveError.corrupt("central directory too large") }
        let cd = try read(at: cdOffset, count: Int(cdSize))

        var entries = [ArchiveEntry]()
        var r = ByteReader(cd)
        while r.remaining > 0 {
            entries.append(try parseCentralHeader(&r))
        }
        // With Zip64 the count is exact; without it, writers that exceed 65535 entries wrap.
        let countOK = UInt64(entries.count) == expectedCount
            || (!isZip64 && UInt64(entries.count % 65536) == expectedCount)
        guard countOK else { throw ArchiveError.corrupt("entry count mismatch") }

        for i in entries.indices {
            try checkLocalHeader(&entries[i], dataLimit: cdOffset)
            let entry = entries[i]
            guard entry.flags & Flag.strongEncryption == 0 else { throw ArchiveError.unsupported("strong encryption") }
            guard entry.method == Method.stored || entry.method == Method.deflated || entry.isDirectory else {
                // Includes 99, WinZip AES.
                throw ArchiveError.unsupported("compression method \(entry.method)")
            }
        }

        // Entries may not share or overlap bytes (the "overlapping files" zip bomb, and
        // local headers referenced twice).
        let spans = entries.map { ($0.localHeaderOffset, $0.endOffset) }.sorted { $0.0 < $1.0 }
        for (a, b) in zip(spans, spans.dropFirst()) where b.0 < a.1 {
            throw ArchiveError.corrupt("overlapping entries")
        }

        try checkLimits(entries, limits)
        return entries
    }

    private func locateCentralDirectory() throws -> (offset: UInt64, size: UInt64, count: UInt64, zip64: Bool) {
        guard fileSize >= 22 else { throw ArchiveError.corrupt("too small for a zip archive") }
        let tailLength = Int(min(fileSize, 22 + 0xFFFF))
        let tailStart = fileSize - UInt64(tailLength)
        let tail = try read(at: tailStart, count: tailLength)

        // The end record is followed only by its comment. Prefer a candidate whose comment
        // length reaches exactly to the end of the file; accept a shorter one otherwise.
        var found: Int?
        var fallback: Int?
        var i = tailLength - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                let commentLength = Int(tail[i + 20]) | Int(tail[i + 21]) << 8
                if i + 22 + commentLength == tailLength { found = i; break }
                if i + 22 + commentLength < tailLength && fallback == nil { fallback = i }
            }
            i -= 1
        }
        guard let eocdIndex = found ?? fallback else { throw ArchiveError.corrupt("no end of central directory") }
        let eocdOffset = tailStart + UInt64(eocdIndex)

        var r = ByteReader(tail, from: eocdIndex + 4)
        let disk = try r.u16(), cdDisk = try r.u16()
        let entriesOnDisk = try r.u16(), totalEntries = try r.u16()
        let cdSize32 = try r.u32(), cdOffset32 = try r.u32()

        var count = UInt64(totalEntries)
        var size = UInt64(cdSize32)
        var offset = UInt64(cdOffset32)
        var cdEnd = eocdOffset
        var zip64 = false

        if eocdOffset >= 20, let locator = try? read(at: eocdOffset - 20, count: 20),
           locator[0] == 0x50, locator[1] == 0x4B, locator[2] == 0x06, locator[3] == 0x07 {
            var l = ByteReader(locator, from: 4)
            let z64Disk = try l.u32()
            let recordOffset = try l.u64()
            let totalDisks = try l.u32()
            guard z64Disk == 0, totalDisks <= 1 else { throw ArchiveError.unsupported("multi-disk archive") }
            guard eocdOffset - 20 >= 56, recordOffset <= eocdOffset - 20 - 56 else {
                throw ArchiveError.corrupt("bad zip64 locator")
            }
            var z = ByteReader(try read(at: recordOffset, count: 56))
            guard try z.u32() == Signature.zip64EndOfCentralDirectory else { throw ArchiveError.corrupt("bad zip64 end record") }
            let recordSize = try z.u64()
            guard let recordEnd = checkedAdd(recordOffset, 12), let end = checkedAdd(recordEnd, recordSize),
                  recordSize >= 44, end <= eocdOffset - 20 else { throw ArchiveError.corrupt("bad zip64 end record size") }
            try z.skip(4) // versions
            let d = try z.u32(), cd = try z.u32()
            guard d == 0, cd == 0 else { throw ArchiveError.unsupported("multi-disk archive") }
            _ = try z.u64()
            let z64Count = try z.u64(), z64Size = try z.u64(), z64Offset = try z.u64()
            // Per field: the 32/16-bit value is authoritative unless it is the placeholder.
            func pick(_ small: UInt64, _ placeholder: UInt64, _ big: UInt64) throws -> UInt64 {
                if small == placeholder { return big }
                guard small == big else { throw ArchiveError.corrupt("zip64 end record disagrees") }
                return small
            }
            count = try pick(count, 0xFFFF, z64Count)
            size = try pick(size, 0xFFFF_FFFF, z64Size)
            offset = try pick(offset, 0xFFFF_FFFF, z64Offset)
            cdEnd = recordOffset
            zip64 = true
        } else {
            guard disk == 0, cdDisk == 0, entriesOnDisk == totalEntries else {
                throw ArchiveError.unsupported("multi-disk archive")
            }
        }

        // The central directory must end exactly where the end records begin. (Archives with
        // data prepended, such as self-extractors, are not supported.)
        guard offset <= cdEnd, size == cdEnd - offset else { throw ArchiveError.corrupt("central directory out of place") }
        return (offset, size, count, zip64)
    }

    private func parseCentralHeader(_ r: inout ByteReader) throws -> ArchiveEntry {
        guard try r.u32() == Signature.centralHeader else { throw ArchiveError.corrupt("bad central header") }
        let madeBy = try r.u16()
        _ = try r.u16() // version needed
        let flags = try r.u16(), method = try r.u16()
        let time = try r.u16(), date = try r.u16()
        let crc = try r.u32()
        var compressed = UInt64(try r.u32()), uncompressed = UInt64(try r.u32())
        let nameLength = Int(try r.u16()), extraLength = Int(try r.u16()), commentLength = Int(try r.u16())
        var diskStart = UInt32(try r.u16())
        _ = try r.u16() // internal attributes
        let external = try r.u32()
        var localOffset = UInt64(try r.u32())
        let name = try r.take(nameLength)
        let extra = try r.take(extraLength)
        try r.skip(commentLength)

        var unixTime: Int?
        var e = ByteReader(extra)
        var sawZip64 = false
        while e.remaining >= 4 {
            let id = try e.u16(), length = Int(try e.u16())
            var field = ByteReader(try e.take(length))
            switch id {
            case ExtraField.zip64 where !sawZip64:
                sawZip64 = true
                // Only the fields whose header value is the placeholder are present, in order.
                if uncompressed == 0xFFFF_FFFF { uncompressed = try field.u64() }
                if compressed == 0xFFFF_FFFF { compressed = try field.u64() }
                if localOffset == 0xFFFF_FFFF { localOffset = try field.u64() }
                if diskStart == 0xFFFF { diskStart = try field.u32() }
            case ExtraField.extendedTimestamp where length >= 5:
                if try field.u8() & 1 != 0 { unixTime = Int(Int32(bitPattern: try field.u32())) }
            default:
                break
            }
        }
        // Up to three trailing bytes (padding some writers add) are ignored; a field whose
        // length runs past the extra data has already thrown.
        guard diskStart == 0 else { throw ArchiveError.unsupported("multi-disk archive") }

        return ArchiveEntry(rawName: name, name: NameEncoding.decode(name, utf8Flag: flags & Flag.utf8 != 0),
                            versionMadeBy: madeBy, flags: flags, method: method,
                            dosTime: DOSDateTime(time: time, date: date), crc: crc,
                            compressedSize: compressed, uncompressedSize: uncompressed,
                            localHeaderOffset: localOffset, externalAttributes: external,
                            unixModificationTime: unixTime)
    }

    /// Cross-checks the local header against the central directory and fills in where the
    /// entry's data starts and ends. `dataLimit` is the start of the central directory.
    private func checkLocalHeader(_ entry: inout ArchiveEntry, dataLimit: UInt64) throws {
        guard dataLimit >= 30, entry.localHeaderOffset <= dataLimit - 30 else {
            throw ArchiveError.corrupt("local header out of range")
        }
        var h = ByteReader(try read(at: entry.localHeaderOffset, count: 30))
        guard try h.u32() == Signature.localHeader else { throw ArchiveError.corrupt("bad local header") }
        _ = try h.u16()
        let flags = try h.u16(), method = try h.u16()
        try h.skip(4) // time, date
        let crc = try h.u32()
        let compressed32 = try h.u32(), uncompressed32 = try h.u32()
        let nameLength = UInt64(try h.u16()), extraLength = UInt64(try h.u16())

        let variableStart = entry.localHeaderOffset + 30
        guard nameLength + extraLength <= dataLimit - variableStart else { throw ArchiveError.corrupt("local header out of range") }
        let variable = try read(at: variableStart, count: Int(nameLength + extraLength))
        guard Array(variable.prefix(Int(nameLength))) == entry.rawName else {
            throw ArchiveError.corrupt("local and central names differ")
        }
        guard method == entry.method,
              flags & Flag.encrypted == entry.flags & Flag.encrypted,
              flags & Flag.dataDescriptor == entry.flags & Flag.dataDescriptor else {
            throw ArchiveError.corrupt("local and central headers differ")
        }

        var localCompressed = UInt64(compressed32), localUncompressed = UInt64(uncompressed32)
        var localZip64 = false
        var e = ByteReader(variable, from: Int(nameLength))
        while e.remaining >= 4 {
            let id = try e.u16(), length = Int(try e.u16())
            let data = try e.take(length)
            if id == ExtraField.zip64 && !localZip64 {
                localZip64 = true
                var z = ByteReader(data)
                // APPNOTE requires both sizes here; tolerate writers that include only the
                // placeholder ones.
                if data.count >= 16 {
                    localUncompressed = try z.u64()
                    localCompressed = try z.u64()
                } else {
                    if uncompressed32 == 0xFFFF_FFFF { localUncompressed = try z.u64() }
                    if compressed32 == 0xFFFF_FFFF { localCompressed = try z.u64() }
                }
            }
        }

        if entry.hasDataDescriptor {
            // Sizes and CRC may be zero here and follow the data instead.
            guard crc == 0 || crc == entry.crc,
                  localCompressed == 0 || localCompressed == entry.compressedSize,
                  localUncompressed == 0 || localUncompressed == entry.uncompressedSize else {
                throw ArchiveError.corrupt("local and central sizes differ")
            }
        } else {
            guard crc == entry.crc, localCompressed == entry.compressedSize,
                  localUncompressed == entry.uncompressedSize else {
                throw ArchiveError.corrupt("local and central sizes differ")
            }
        }

        entry.dataOffset = variableStart + nameLength + extraLength
        guard entry.compressedSize <= dataLimit - entry.dataOffset else { throw ArchiveError.corrupt("entry data out of range") }
        var end = entry.dataOffset + entry.compressedSize

        if entry.hasDataDescriptor {
            // Optional signature, CRC, then 4- or 8-byte sizes (8 when the entry uses Zip64).
            let wide = localZip64 || entry.compressedSize >= 0xFFFF_FFFF || entry.uncompressedSize >= 0xFFFF_FFFF
            let available = Int(min(dataLimit - end, 24))
            var d = ByteReader(try read(at: end, count: available))
            var length = 0
            var first = try d.u32()
            if first == Signature.dataDescriptor {
                length += 4
                first = try d.u32()
            }
            guard first == entry.crc else { throw ArchiveError.corrupt("data descriptor CRC differs") }
            let c = wide ? try d.u64() : UInt64(try d.u32())
            let u = wide ? try d.u64() : UInt64(try d.u32())
            guard c == entry.compressedSize, u == entry.uncompressedSize else {
                throw ArchiveError.corrupt("data descriptor sizes differ")
            }
            length += 4 + (wide ? 16 : 8)
            end += UInt64(length)
        }
        entry.endOffset = end
    }

    private func checkLimits(_ entries: [ArchiveEntry], _ limits: ZipLimits) throws {
        var total: UInt64 = 0
        var totalCompressed: UInt64 = 0
        for entry in entries where !entry.isDirectory {
            guard let t = checkedAdd(total, entry.uncompressedSize), t <= limits.maxTotalUncompressedSize else {
                throw ArchiveError.limitExceeded("total uncompressed size")
            }
            total = t
            totalCompressed = checkedAdd(totalCompressed, entry.compressedSize) ?? .max
            if entry.uncompressedSize >= Self.ratioCheckFloor,
               entry.uncompressedSize / max(entry.compressedSize, 1) > limits.maxCompressionRatio {
                throw ArchiveError.limitExceeded("compression ratio")
            }
        }
        // The same ratio over the whole archive, so a bomb split into many entries just under
        // the per-entry floor is caught too.
        if total >= Self.ratioCheckFloor, total / max(totalCompressed, 1) > limits.maxCompressionRatio {
            throw ArchiveError.limitExceeded("total compression ratio")
        }
    }

    // MARK: Data

    /// Checks an encrypted entry's password against the header's check byte. One byte means a
    /// wrong password slips through about 1 time in 256; it then fails the CRC check instead.
    func checkPassword(_ entry: ArchiveEntry, _ password: [UInt8]) throws {
        guard entry.compressedSize >= UInt64(ZipCrypto.headerSize) else { throw ArchiveError.corrupt("short encryption header") }
        var crypto = ZipCrypto(password: password)
        let expected = entry.hasDataDescriptor ? UInt8(entry.dosTime.time >> 8) : UInt8(entry.crc >> 24)
        guard crypto.checkByte(header: try read(at: entry.dataOffset, count: ZipCrypto.headerSize)) == expected else {
            throw ArchiveError.incorrectPassword
        }
    }

    /// Streams the entry's decompressed bytes to `sink` through two fixed buffers, verifying
    /// that exactly the declared number of bytes comes out and that the CRC matches.
    func extract(_ entry: ArchiveEntry, password: [UInt8]?, input: UnsafeMutableRawPointer,
                 output: UnsafeMutableRawPointer, sink: (UnsafeRawPointer, Int) throws -> Void) throws {
        guard entry.flags & Flag.strongEncryption == 0 else { throw ArchiveError.unsupported("strong encryption") }
        var position = entry.dataOffset
        var remaining = entry.compressedSize
        var crypto: ZipCrypto?
        if entry.isEncrypted {
            guard let password, !password.isEmpty else { throw ArchiveError.incorrectPassword }
            try checkPassword(entry, password)
            var c = ZipCrypto(password: password)
            _ = c.checkByte(header: try read(at: position, count: ZipCrypto.headerSize))
            crypto = c
            position += UInt64(ZipCrypto.headerSize)
            remaining -= UInt64(ZipCrypto.headerSize)
        }

        let size = Self.bufferSize
        var crc: UInt32 = 0
        var produced: UInt64 = 0
        func emit(_ base: UnsafeRawPointer, _ n: Int) throws {
            guard n > 0 else { return }
            guard let p = checkedAdd(produced, UInt64(n)), p <= entry.uncompressedSize else {
                throw ArchiveError.corrupt("more data than declared")
            }
            produced = p
            crc = crc32Update(crc, base, n)
            try sink(base, n)
        }
        func fill() throws -> Int {
            let n = Int(min(remaining, UInt64(size)))
            try read(at: position, into: input, count: n)
            crypto?.decrypt(UnsafeMutableRawBufferPointer(start: input, count: n))
            position += UInt64(n)
            remaining -= UInt64(n)
            return n
        }

        switch entry.method {
        case Method.stored:
            guard remaining == entry.uncompressedSize else { throw ArchiveError.corrupt("stored sizes differ") }
            while remaining > 0 {
                let n = try fill()
                try emit(input, n)
            }
        case Method.deflated:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ArchiveError.io("inflateInit2")
            }
            defer { inflateEnd(&stream) }
            var finished = false
            while !finished {
                if stream.avail_in == 0 && remaining > 0 {
                    let n = try fill()
                    stream.next_in = input.assumingMemoryBound(to: Bytef.self)
                    stream.avail_in = UInt32(n)
                }
                let inputBefore = stream.avail_in
                stream.next_out = output.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = UInt32(size)
                let ret = inflate(&stream, Z_NO_FLUSH)
                let have = size - Int(stream.avail_out)
                try emit(output, have)
                switch ret {
                case Z_STREAM_END:
                    finished = true
                case Z_OK, Z_BUF_ERROR:
                    // No progress and no more input: the stream is truncated. (This also
                    // rules out spinning forever on a stream that never ends.)
                    if have == 0 && stream.avail_in == inputBefore {
                        throw ArchiveError.corrupt("truncated deflate stream")
                    }
                default:
                    throw ArchiveError.corrupt("bad deflate stream")
                }
            }
            guard stream.avail_in == 0 && remaining == 0 else { throw ArchiveError.corrupt("data after deflate stream") }
        default:
            throw ArchiveError.unsupported("compression method \(entry.method)")
        }

        guard produced == entry.uncompressedSize else { throw ArchiveError.corrupt("less data than declared") }
        guard crc == entry.crc else { throw ArchiveError.corrupt("CRC mismatch") }
    }
}
