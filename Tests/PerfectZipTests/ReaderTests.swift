import Testing
import Foundation
@testable import PerfectZip

/// Structural robustness of the archive reader: hostile or damaged structure fails cleanly
/// and before anything is written.
@Suite struct ReaderTests {

    private func structureError(_ path: String, limits: ZipLimits = .default) -> ArchiveError? {
        do {
            _ = try ArchiveReader(path: path).entries(limits: limits)
            return nil
        } catch let e as ArchiveError {
            return e
        } catch {
            return .io("\(error)")
        }
    }

    /// Offset of the first central directory header.
    private func centralOffset(_ bytes: [UInt8]) -> Int { find(le32(Signature.centralHeader), in: bytes)! }

    @Test func overlappingEntriesAreRefused() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "one"), RawEntry(name: "a.txt", contents: "one")])
        var bytes = try scratch.bytes("a.zip")
        // Point the second central record at the first local header (same name, same data).
        let first = centralOffset(bytes)
        let second = find(le32(Signature.centralHeader), in: bytes, from: first + 4)!
        bytes.replaceSubrange(second + 42..<second + 46, with: le32(0))
        try scratch.writeBytes("a.zip", bytes)
        #expect(structureError(scratch.sub("a.zip")) == .corrupt("overlapping entries"))
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("dest")))
    }

    @Test func localHeaderMustMatchCentral() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "one")])
        var bytes = try scratch.bytes("a.zip")
        bytes[30] = UInt8(ascii: "b") // local name "b.txt", central still "a.txt"
        try scratch.writeBytes("a.zip", bytes)
        #expect(structureError(scratch.sub("a.zip")) == .corrupt("local and central names differ"))
    }

    @Test func centralSizesMustMatchLocal() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: String(repeating: "x", count: 100))])
        var bytes = try scratch.bytes("a.zip")
        let c = centralOffset(bytes)
        bytes[c + 24] &+= 1 // central uncompressed size
        try scratch.writeBytes("a.zip", bytes)
        #expect(structureError(scratch.sub("a.zip")) == .corrupt("local and central sizes differ"))
    }

    /// Both headers agree on a size smaller than the real data: extraction stops at the
    /// declared size and removes the partial file.
    @Test func moreDataThanDeclaredIsRefused() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: String(repeating: "x", count: 100))])
        var bytes = try scratch.bytes("a.zip")
        let c = centralOffset(bytes)
        bytes.replaceSubrange(22..<26, with: le32(10))
        bytes.replaceSubrange(c + 24..<c + 28, with: le32(10))
        try scratch.writeBytes("a.zip", bytes)
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("dest/a.txt")))
    }

    @Test(arguments: [ArchiveWriter.SizeStyle.descriptorWithSignature, .descriptorWithoutSignature])
    func dataDescriptors(style: ArchiveWriter.SizeStyle) throws {
        let scratch = try Scratch()
        let text = String(repeating: "descriptor ", count: 500)
        try makeArchive(at: scratch.sub("a.zip"), [
            RawEntry(name: "a.txt", contents: text, style: style),
            RawEntry(name: "empty.txt", contents: "", style: style),
            RawEntry(name: "b.txt", contents: "b", style: style),
        ])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        #expect(scratch.read("dest/a.txt") == text)
        #expect(scratch.read("dest/empty.txt") == "")
        #expect(scratch.read("dest/b.txt") == "b")
        if let r = run("python3", ["-I", "-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None", scratch.sub("a.zip")]) {
            #expect(r.status == 0, "\(r.output)")
        }
    }

    @Test func cp437NamesAreDecoded() throws {
        let scratch = try Scratch()
        // "café" with é as CP437 0x82, UTF-8 flag clear: not valid UTF-8, so CP437.
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(nameBytes: [0x63, 0x61, 0x66, 0x82], contents: [1], utf8Flag: false)])
        #expect(try entryNames(of: scratch.sub("a.zip")) == ["café"])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        #expect(FileManager.default.fileExists(atPath: scratch.sub("dest/café")))
    }

    @Test func utf8NamesWithoutFlagStayUTF8() throws {
        #expect(NameEncoding.decode(Array("日本/ü.txt".utf8), utf8Flag: false) == "日本/ü.txt")
        #expect(NameEncoding.decode([0x82, 0x2F, 0x41], utf8Flag: false) == "é/A")
        #expect(NameEncoding.decode([0x82], utf8Flag: true) == nil)
    }

    // MARK: Zip bombs

    @Test func compressionRatioLimit() throws {
        let scratch = try Scratch()
        let zeros = String(repeating: "\0", count: 10 << 20) // 10 MiB of zeros, ~1000:1
        try makeArchive(at: scratch.sub("bomb.zip"), [RawEntry(name: "zeros.bin", contents: zeros)])
        #expect(Zip().unzipFile(source: scratch.sub("bomb.zip"), destination: scratch.sub("d1"), overwrite: true) == .UnzipLimitExceeded)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("d1")))
        let relaxed = Zip(limits: ZipLimits(maxCompressionRatio: 2000))
        #expect(relaxed.unzipFile(source: scratch.sub("bomb.zip"), destination: scratch.sub("d2"), overwrite: true) == .ZipSuccess)
        #expect((try FileManager.default.attributesOfItem(atPath: scratch.sub("d2/zeros.bin"))[.size] as? Int) == 10 << 20)
    }

    @Test func totalSizeLimit() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a", contents: String(repeating: "a", count: 600)),
                                                   RawEntry(name: "b", contents: String(repeating: "b", count: 600))])
        let tight = Zip(limits: ZipLimits(maxTotalUncompressedSize: 1000))
        #expect(tight.unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("d"), overwrite: true) == .UnzipLimitExceeded)
        #expect(Zip(limits: ZipLimits(maxTotalUncompressedSize: 1200)).unzipFile(
            source: scratch.sub("a.zip"), destination: scratch.sub("d"), overwrite: true) == .ZipSuccess)
    }

    // MARK: Damaged structure

    @Test func notAnArchive() throws {
        let scratch = try Scratch()
        for (name, bytes) in [("empty.zip", [UInt8]()), ("short.zip", [0x50, 0x4B, 0x05, 0x06]),
                              ("text.zip", Array(String(repeating: "not a zip ", count: 100).utf8))] {
            try scratch.writeBytes(name, bytes)
            #expect(Zip().unzipFile(source: scratch.sub(name), destination: scratch.sub("d-\(name)"), overwrite: true) == .UnzipFail)
        }
        // A directory is not an archive either.
        try scratch.makeDirectory("dir.zip")
        #expect(Zip().unzipFile(source: scratch.sub("dir.zip"), destination: scratch.sub("d"), overwrite: true) == .UnzipFail)
    }

    /// Self-extractor style data in front of the archive moves every offset; such archives are
    /// refused rather than guessed at.
    @Test func prependedDataIsRefused() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "a")])
        try scratch.writeBytes("b.zip", Array("#!/bin/sh\nexit 0\n".utf8) + scratch.bytes("a.zip"))
        #expect(structureError(scratch.sub("b.zip")) == .corrupt("central directory out of place"))
    }

    @Test func manyEntriesUseZip64EndRecords() throws {
        let scratch = try Scratch()
        let n = 70_000 // more than 0xFFFF
        try makeArchive(at: scratch.sub("many.zip"), (0..<n).map { RawEntry(name: "d\($0 % 100)/f\($0)", contents: "") })
        let bytes = try scratch.bytes("many.zip")
        #expect(find(le32(Signature.zip64EndOfCentralDirectory), in: bytes, from: bytes.count - 200) != nil)
        // The classic end record says 0xFFFF, the Zip64 one has the real count.
        #expect(Array(bytes[(bytes.count - 22 + 8)..<(bytes.count - 22 + 12)]) == [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(try entryNames(of: scratch.sub("many.zip")).count == n)
        if let r = run("python3", ["-I", "-c", "import zipfile,sys; print(len(zipfile.ZipFile(sys.argv[1]).infolist()))", scratch.sub("many.zip")]) {
            #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "\(n)")
        }
    }

    @Test func unsupportedMethodIsRefused() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: String(repeating: "x", count: 100))])
        var bytes = try scratch.bytes("a.zip")
        let c = centralOffset(bytes)
        bytes[8] = 12; bytes[c + 10] = 12 // bzip2, in both headers
        try scratch.writeBytes("a.zip", bytes)
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("d"), overwrite: true) == .UnzipFail)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("d/a.txt")))
    }
}
