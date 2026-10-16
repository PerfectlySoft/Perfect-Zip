import Testing
import Foundation
@testable import PerfectZip

/// Opt-in: `PERFECTZIP_LARGE_TESTS=1 swift test --filter LargeFileTests`. Needs about 5 GB of
/// free disk for the extracted copy (the source is sparse) and takes a minute or two.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PERFECTZIP_LARGE_TESTS"] == "1"))
struct LargeFileTests {

    /// CRC-32 and size of a file, streamed.
    private func digest(_ path: String) throws -> (UInt32, UInt64) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ArchiveError.io("open") }
        defer { close(fd) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var crc: UInt32 = 0
        var total: UInt64 = 0
        while true {
            let n = read(fd, buffer, 1 << 20)
            guard n >= 0 else { throw ArchiveError.io("read") }
            if n == 0 { break }
            crc = crc32Update(crc, buffer, n)
            total += UInt64(n)
        }
        return (crc, total)
    }

    @Test func fiveGigabyteSparseFile() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        let path = scratch.sub("src/big.bin")
        let size: UInt64 = 5 << 30
        // Sparse 5 GiB with random 1 MiB islands, including one straddling the 4 GiB mark.
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        for offset: UInt64 in [0, 1 << 30, (4 << 30) - (1 << 19), size - (1 << 20)] {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) }))
        }
        try handle.truncate(atOffset: size)
        try handle.close()
        try scratch.write("src/small.txt", "after the big one")

        let archive = scratch.sub("big.zip")
        #expect(Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: archive, overwrite: true) == .ZipSuccess)
        let entries = try ArchiveReader(path: archive).entries(limits: .unlimited)
        let big = try #require(entries.first { $0.name == "src/big.bin" })
        #expect(big.uncompressedSize == size)
        // small.txt's local header lies past 4 GiB only if big.bin compressed poorly; at least
        // the sizes must have needed Zip64.
        #expect(big.uncompressedSize > 0xFFFF_FFFF)

        // The default ratio limit treats this (mostly zeros) as a bomb.
        #expect(Zip().unzipFile(source: archive, destination: scratch.sub("refused"), overwrite: true) == .UnzipLimitExceeded)

        #expect(Zip(limits: .unlimited).unzipFile(source: archive, destination: scratch.sub("out"), overwrite: true) == .ZipSuccess)
        let (crcIn, sizeIn) = try digest(path)
        let (crcOut, sizeOut) = try digest(scratch.sub("out/src/big.bin"))
        #expect(sizeIn == size && sizeOut == size)
        #expect(crcIn == crcOut && crcOut == big.crc)
        #expect(scratch.read("out/src/small.txt") == "after the big one")
        try FileManager.default.removeItem(atPath: scratch.sub("out"))

        if let r = run("unzip", ["-tq", archive]) { #expect(r.status == 0, "\(r.output)") }
        if let r = run("python3", ["-I", "-c", "import zipfile,sys; assert zipfile.ZipFile(sys.argv[1]).testzip() is None", archive]) {
            #expect(r.status == 0, "\(r.output)")
        }
    }
}
