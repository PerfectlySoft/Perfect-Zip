import Foundation
internal import CZlib

/// Writes a zip archive sequentially to a new file. Entry data is streamed through fixed
/// buffers; each local header is written first and its CRC and sizes patched in afterwards
/// with `pwrite`, so no data descriptors are needed. Zip64 fields are written when an entry,
/// an offset, the central directory or the entry count needs them.
final class ArchiveWriter {
    private let fd: Int32
    private var offset: UInt64 = 0
    private var central: [UInt8] = []
    private var count: UInt64 = 0
    private let input: UnsafeMutableRawPointer
    private let output: UnsafeMutableRawPointer
    private var closed = false

    static let bufferSize = 64 * 1024
    /// Unix host (3), APPNOTE version 4.5 (Zip64).
    static let versionMadeBy: UInt16 = 0x032D
    /// Entries whose source is at least this large get Zip64 sizes up front. Leaves room for
    /// deflate's worst-case expansion of incompressible data just under 4 GiB.
    static let zip64Threshold: UInt64 = 0xFF00_0000

    /// How an entry's CRC and sizes are recorded. Only tests use the descriptor styles.
    enum SizeStyle { case patched, descriptorWithSignature, descriptorWithoutSignature }

    init(path: String) throws {
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw ArchiveError.io("create archive") }
        input = .allocate(byteCount: Self.bufferSize, alignment: 16)
        output = .allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        if !closed { closeFD(fd) }
        input.deallocate()
        output.deallocate()
    }

    private func append(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try append($0.baseAddress!, $0.count) }
    }

    private func append(_ base: UnsafeRawPointer, _ n: Int) throws {
        guard n > 0 else { return }
        guard writeAll(fd, base, n) else { throw ArchiveError.io("write") }
        offset += UInt64(n)
    }

    private func patch(_ bytes: [UInt8], at position: UInt64) throws {
        try bytes.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(position + UInt64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ArchiveError.io("write") }
                done += n
            }
        }
    }

    /// Adds one entry. `source` fills the buffer and returns the byte count, 0 at the end;
    /// nil means a directory. `name` is raw bytes: callers are responsible for it being a safe
    /// relative path (``Zipper`` builds names from directory listings).
    func add(name: [UInt8], isDirectory: Bool, unixMode: UInt32?, modified: Int, sizeHint: UInt64,
             style: SizeStyle = .patched, utf8Flag: Bool? = nil,
             source: ((UnsafeMutableRawPointer, Int) throws -> Int)?) throws {
        guard name.count <= 0xFFFF else { throw ArchiveError.unsupported("name too long") }
        let method = isDirectory || sizeHint == 0 ? Method.stored : Method.deflated
        let zip64 = sizeHint >= Self.zip64Threshold
        let descriptor = style != .patched
        var flags: UInt16 = (utf8Flag ?? name.contains { $0 >= 0x80 }) ? Flag.utf8 : 0
        if descriptor { flags |= Flag.dataDescriptor }
        let needed: UInt16 = zip64 ? 45 : (method == Method.deflated ? 20 : 10)
        let dos = DOSDateTime(modified)
        let utc = UInt32(bitPattern: Int32(clamping: modified))
        let localOffset = offset

        var timestamp = [UInt8]()
        timestamp.le16(ExtraField.extendedTimestamp); timestamp.le16(5); timestamp.append(1); timestamp.le32(utc)

        var local = [UInt8]()
        local.le32(Signature.localHeader)
        local.le16(needed); local.le16(flags); local.le16(method)
        local.le16(dos.time); local.le16(dos.date)
        local.le32(0)
        local.le32(zip64 ? 0xFFFF_FFFF : 0); local.le32(zip64 ? 0xFFFF_FFFF : 0)
        local.le16(UInt16(name.count))
        local.le16(UInt16((zip64 ? 20 : 0) + timestamp.count))
        local += name
        let zip64ExtraOffset = localOffset + UInt64(local.count) + 4
        if zip64 { local.le16(ExtraField.zip64); local.le16(16); local.le64(0); local.le64(0) }
        local += timestamp
        try append(local)

        // Data.
        let dataStart = offset
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        if let source {
            if method == Method.stored {
                while true {
                    let n = try source(input, Self.bufferSize)
                    if n == 0 { break }
                    crc = crc32Update(crc, input, n)
                    uncompressed += UInt64(n)
                    try append(input, n)
                }
            } else {
                var stream = z_stream()
                guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                    zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw ArchiveError.io("deflateInit2")
                }
                defer { deflateEnd(&stream) }
                var finished = false
                while !finished {
                    let n = try source(input, Self.bufferSize)
                    crc = crc32Update(crc, input, n)
                    uncompressed += UInt64(n)
                    stream.next_in = input.assumingMemoryBound(to: Bytef.self)
                    stream.avail_in = UInt32(n)
                    let flush = n == 0 ? Z_FINISH : Z_NO_FLUSH
                    repeat {
                        stream.next_out = output.assumingMemoryBound(to: Bytef.self)
                        stream.avail_out = UInt32(Self.bufferSize)
                        let ret = deflate(&stream, flush)
                        guard ret == Z_OK || ret == Z_STREAM_END || ret == Z_BUF_ERROR else { throw ArchiveError.io("deflate") }
                        try append(output, Self.bufferSize - Int(stream.avail_out))
                        if ret == Z_STREAM_END { finished = true }
                    } while stream.avail_out == 0
                }
            }
        }
        let compressed = offset - dataStart
        if !zip64 && (compressed >= 0xFFFF_FFFF || uncompressed >= 0xFFFF_FFFF) {
            // The source grew past the size it had when the header was written.
            throw ArchiveError.unsupported("entry grew past 4 GiB while being archived")
        }

        switch style {
        case .patched:
            var fields = [UInt8]()
            fields.le32(crc)
            if zip64 {
                try patch(fields, at: localOffset + 14)
                var sizes = [UInt8]()
                sizes.le64(uncompressed); sizes.le64(compressed)
                try patch(sizes, at: zip64ExtraOffset)
            } else {
                fields.le32(UInt32(compressed)); fields.le32(UInt32(uncompressed))
                try patch(fields, at: localOffset + 14)
            }
        case .descriptorWithSignature, .descriptorWithoutSignature:
            var d = [UInt8]()
            if style == .descriptorWithSignature { d.le32(Signature.dataDescriptor) }
            d.le32(crc)
            if zip64 { d.le64(compressed); d.le64(uncompressed) } else { d.le32(UInt32(compressed)); d.le32(UInt32(uncompressed)) }
            try append(d)
        }

        // Central directory record; Zip64 extra only for the fields that overflow.
        var z64 = [UInt8]()
        if uncompressed >= 0xFFFF_FFFF { z64.le64(uncompressed) }
        if compressed >= 0xFFFF_FFFF { z64.le64(compressed) }
        if localOffset >= 0xFFFF_FFFF { z64.le64(localOffset) }
        var extra = [UInt8]()
        if !z64.isEmpty { extra.le16(ExtraField.zip64); extra.le16(UInt16(z64.count)); extra += z64 }
        extra += timestamp

        let fileType = isDirectory ? FileType.directory : FileType.regular
        let mode = (unixMode ?? (isDirectory ? 0o755 : 0o644))
        let external = (mode & FileType.mask == 0 ? mode | fileType : mode) << 16 | (isDirectory ? 0x10 : 0)

        var c = [UInt8]()
        c.le32(Signature.centralHeader)
        c.le16(Self.versionMadeBy); c.le16(max(needed, z64.isEmpty ? needed : 45))
        c.le16(flags); c.le16(method); c.le16(dos.time); c.le16(dos.date)
        c.le32(crc)
        c.le32(UInt32(min(compressed, 0xFFFF_FFFF))); c.le32(UInt32(min(uncompressed, 0xFFFF_FFFF)))
        c.le16(UInt16(name.count)); c.le16(UInt16(extra.count)); c.le16(0)
        c.le16(0); c.le16(0); c.le32(external)
        c.le32(UInt32(min(localOffset, 0xFFFF_FFFF)))
        c += name
        c += extra
        central += c
        count += 1
    }

    /// Writes the central directory and end records and closes the file.
    func finish() throws {
        let cdOffset = offset
        try append(central)
        let cdSize = UInt64(central.count)
        if count >= 0xFFFF || cdOffset >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF {
            let recordOffset = offset
            var z = [UInt8]()
            z.le32(Signature.zip64EndOfCentralDirectory); z.le64(44)
            z.le16(Self.versionMadeBy); z.le16(45)
            z.le32(0); z.le32(0)
            z.le64(count); z.le64(count); z.le64(cdSize); z.le64(cdOffset)
            z.le32(Signature.zip64Locator); z.le32(0); z.le64(recordOffset); z.le32(1)
            try append(z)
        }
        var e = [UInt8]()
        e.le32(Signature.endOfCentralDirectory)
        e.le16(0); e.le16(0)
        e.le16(UInt16(min(count, 0xFFFF))); e.le16(UInt16(min(count, 0xFFFF)))
        e.le32(UInt32(min(cdSize, 0xFFFF_FFFF))); e.le32(UInt32(min(cdOffset, 0xFFFF_FFFF)))
        e.le16(0)
        try append(e)
        closed = true
        guard close(fd) == 0 else { throw ArchiveError.io("close") }
    }
}
