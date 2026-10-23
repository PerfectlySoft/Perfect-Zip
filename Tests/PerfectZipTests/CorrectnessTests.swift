import Testing
import Foundation
@testable import PerfectZip

@Suite struct CorrectnessTests {

    private func roundTrip(_ scratch: Scratch) throws -> ZipStatus {
        try scratch.makeDirectory("src/empty")
        try scratch.write("src/a.txt", String(repeating: "hello zip ", count: 10_000))
        let zipped = Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"), overwrite: true)
        #expect(zipped == .ZipSuccess)
        return Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true)
    }

    /// ZipCrypto archives written by Info-ZIP `zip -P` (deflated and stored entries, both with
    /// data descriptors, so the check byte comes from the DOS time) can be read.
    @Test func readsZipCrypto() throws {
        let scratch = try Scratch()
        try zipCryptoFixture.write(to: URL(fileURLWithPath: scratch.sub("enc.zip")))
        let status = Zip().unzipFile(source: scratch.sub("enc.zip"), destination: scratch.sub("dest"),
                                     overwrite: true, password: "pässword")
        #expect(status == .ZipSuccess)
        #expect(scratch.read("dest/deflated.txt") == String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40))
        #expect(scratch.read("dest/stored.txt") == "stored secret\n")
    }

    /// Without the password, or with a wrong one, nothing is written at all.
    @Test(arguments: ["", "wrong", "password"])
    func zipCryptoMissingOrWrongPassword(password: String) throws {
        let scratch = try Scratch()
        try zipCryptoFixture.write(to: URL(fileURLWithPath: scratch.sub("enc.zip")))
        let status = Zip().unzipFile(source: scratch.sub("enc.zip"), destination: scratch.sub("dest"),
                                     overwrite: true, password: password)
        #expect(status == .UnzipIncorrectPassword)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("dest")))
    }

    /// Writing encrypted archives is no longer supported; the deprecated overload says so.
    @Test func zipWithPasswordIsRefused() throws {
        let scratch = try Scratch()
        try scratch.write("a.txt", "a")
        let legacy: any LegacyZipping = Zip()
        #expect(legacy.zipFiles(paths: [scratch.sub("a.txt")], zipFilePath: scratch.sub("a.zip"), overwrite: true, password: "pw")
                == .ZipEncryptionUnsupported)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("a.zip")))
        #expect(legacy.zipFiles(paths: [scratch.sub("a.txt")], zipFilePath: scratch.sub("a.zip"), overwrite: true, password: nil)
                == .ZipSuccess)
        #expect(legacy.zipFiles(paths: [scratch.sub("a.txt")], zipFilePath: scratch.sub("b.zip"), overwrite: true, password: "")
                == .ZipSuccess)
    }

    @Test func emptyDirectoriesAreKept() throws {
        let scratch = try Scratch()
        #expect(try roundTrip(scratch) == .ZipSuccess)
        #expect(scratch.read("dest/src/a.txt") == scratch.read("src/a.txt"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.sub("dest/src/empty"), isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func emptyArchive() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("empty.zip"), [])
        #expect(Zip().unzipFile(source: scratch.sub("empty.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        // The writer's output for an empty archive is the bare 22-byte end record.
        #expect(try scratch.bytes("empty.zip").count == 22)
    }

    @Test func permissionsAndTimestampsSurvive() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        try scratch.write("src/run.sh", "#!/bin/sh\n")
        let fm = FileManager.default
        let when = Date(timeIntervalSince1970: 1_600_000_000) // even second: DOS time has 2 s steps
        try fm.setAttributes([.posixPermissions: 0o750, .modificationDate: when], ofItemAtPath: scratch.sub("src/run.sh"))

        #expect(Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"), overwrite: true) == .ZipSuccess)
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)

        let attrs = try fm.attributesOfItem(atPath: scratch.sub("dest/src/run.sh"))
        #expect((attrs[.posixPermissions] as? Int) == 0o750 & ~(try processUmask(scratch)))
        #expect((attrs[.modificationDate] as? Date) == when)
    }

    /// The process umask, read the way the extractor does (a probe file created 0o777), since
    /// setting it in a test would race with the tests running in parallel.
    private func processUmask(_ scratch: Scratch) throws -> Int {
        let probe = scratch.sub("umask-probe")
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o777)
        defer { if fd >= 0 { close(fd) }; unlink(probe) }
        return ~mode(probe) & 0o777
    }

    /// Recorded modes are masked by the umask, as with bsdtar: an archive cannot create a
    /// world-writable file. Under the usual umask 022, 0o777 becomes 0o755.
    @Test func recordedModesHonourUmask() throws {
        let scratch = try Scratch()
        let umask = try processUmask(scratch)
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "open", contents: "x", unixMode: 0o100777),
                                                   RawEntry(name: "suid", contents: "x", unixMode: 0o107777)])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        #expect(mode(scratch.sub("dest/open")) == 0o777 & ~umask)
        #expect(mode(scratch.sub("dest/suid")) == 0o777 & ~umask)
        if umask == 0o022 {
            #expect(mode(scratch.sub("dest/open")) == 0o755)
        }
        #expect(umask & 0o002 == 0 || mode(scratch.sub("dest/open")) & 0o002 == 0)
        // No probe files are left in the destination.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.sub("dest")).sorted() == ["open", "suid"])
    }

    /// A read-only destination works when nothing has to be written to it: the umask probe is
    /// only made when a recorded mode is applied, in the entry's own (writable) directory.
    @Test func readOnlyDestinationNeedingNoWrites() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("empty.zip"), [])
        try makeArchive(at: scratch.sub("dirs.zip"), [RawEntry(name: "sub/")])
        try makeArchive(at: scratch.sub("mac.zip"), [RawEntry(name: "__MACOSX/._x", contents: "m")])
        try makeArchive(at: scratch.sub("file.zip"), [RawEntry(name: "f", contents: "x")])
        let ro = try scratch.makeDirectory("ro")
        try scratch.makeDirectory("ro/sub")
        chmod(ro, 0o555)
        defer { chmod(ro, 0o755) }
        for name in ["empty", "dirs", "mac"] {
            #expect(Zip().unzipFile(source: scratch.sub("\(name).zip"), destination: ro, overwrite: true) == .ZipSuccess, "\(name)")
        }
        if getuid() != 0 { // root can write anyway
            #expect(Zip().unzipFile(source: scratch.sub("file.zip"), destination: ro, overwrite: true) == .UnzipFail)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: ro).sorted() == ["sub"])
    }

    /// Entries in a subdirectory: the probe goes there and is removed.
    @Test func umaskProbeLeavesNothing() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "x/y/a", contents: "x", unixMode: 0o100777),
                                                   RawEntry(name: "x/b", contents: "x", unixMode: 0o100640)])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("d"), overwrite: false) == .ZipSuccess)
        let all = try FileManager.default.subpathsOfDirectory(atPath: scratch.sub("d"))
        #expect(!all.contains { $0.contains(".perfectzip-") })
        #expect(mode(scratch.sub("d/x/y/a")) == 0o777 & ~(try processUmask(scratch)))
        #expect(mode(scratch.sub("d/x/b")) == 0o640 & ~(try processUmask(scratch)))
    }

    @Test func setuidBitsAreNotRestored() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "x", contents: "x", unixMode: 0o104755)])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        let attrs = try FileManager.default.attributesOfItem(atPath: scratch.sub("dest/x"))
        #expect((attrs[.posixPermissions] as? Int) == 0o755 & ~(try processUmask(scratch)))
    }

    @Test func duplicateEntriesNeedOverwrite() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("dup.zip"), [RawEntry(name: "a.txt", contents: "1"), RawEntry(name: "a.txt", contents: "2")])
        #expect(Zip().unzipFile(source: scratch.sub("dup.zip"), destination: scratch.sub("d1"), overwrite: false) == .ZipCannotOverwrite)
        #expect(Zip().unzipFile(source: scratch.sub("dup.zip"), destination: scratch.sub("d2"), overwrite: true) == .ZipSuccess)
        #expect(scratch.read("d2/a.txt") == "2")
    }

    @Test func overwriteReplacesExistingFile() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("dest")
        try scratch.write("dest/a.txt", "old and longer")
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "new")])
        let st = Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true)
        #expect(st == .ZipSuccess)
        #expect(scratch.read("dest/a.txt") == "new")
    }

    private func mode(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
    }

    /// Rewrites every central "version made by" host to MS-DOS, as a Windows tool would, so the
    /// entries carry no Unix mode.
    private func makeDOSHost(_ scratch: Scratch, _ name: String) throws {
        var bytes = try scratch.bytes(name)
        var at = 0
        while let c = find(le32(Signature.centralHeader), in: bytes, from: at) { bytes[c + 5] = 0; at = c + 4 }
        try scratch.writeBytes(name, bytes)
    }

    private func noTemporaries(_ dir: String) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasPrefix(".perfectzip-") }
    }

    /// A replacement that fails (here, a CRC error) leaves the original file untouched.
    @Test func failedReplaceKeepsOriginal() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("dest")
        try scratch.write("dest/a.txt", "USER DATA")
        try makeArchive(at: scratch.sub("x.zip"), [RawEntry(name: "a.txt", contents: "new contents")])
        var bytes = try scratch.bytes("x.zip")
        let c = find(le32(Signature.centralHeader), in: bytes)!
        bytes[14] ^= 1; bytes[c + 16] ^= 1 // CRC, in both headers
        try scratch.writeBytes("x.zip", bytes)
        #expect(Zip().unzipFile(source: scratch.sub("x.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
        #expect(scratch.read("dest/a.txt") == "USER DATA")
        #expect(noTemporaries(scratch.sub("dest")))
    }

    /// Without a Unix mode in the archive, a replaced file keeps its permissions (a private
    /// file stays private), including a read-only one, which is replaced.
    @Test(arguments: [0o600, 0o444, 0o751])
    func replacedFileKeepsMode(original: Int) throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("dest")
        try scratch.write("dest/f.txt", "old")
        try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: scratch.sub("dest/f.txt"))
        try makeArchive(at: scratch.sub("x.zip"), [RawEntry(name: "f.txt", contents: "new")])
        try makeDOSHost(scratch, "x.zip")
        #expect(Zip().unzipFile(source: scratch.sub("x.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        #expect(scratch.read("dest/f.txt") == "new")
        #expect(mode(scratch.sub("dest/f.txt")) == original)
        #expect(noTemporaries(scratch.sub("dest")))
    }

    /// With a Unix mode in the archive, that mode wins.
    @Test func replacedFileTakesArchiveMode() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("dest")
        try scratch.write("dest/f.txt", "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.sub("dest/f.txt"))
        try makeArchive(at: scratch.sub("x.zip"), [RawEntry(name: "f.txt", contents: "new", unixMode: 0o100755)])
        #expect(Zip().unzipFile(source: scratch.sub("x.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        #expect(mode(scratch.sub("dest/f.txt")) == 0o755 & ~(try processUmask(scratch)))
    }

    /// A file entry where the destination has a directory fails, and the directory's contents
    /// are untouched.
    @Test func fileOverDirectoryFails() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("dest/a")
        try scratch.write("dest/a/keep.txt", "keep")
        try makeArchive(at: scratch.sub("x.zip"), [RawEntry(name: "a", contents: "file")])
        #expect(Zip().unzipFile(source: scratch.sub("x.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
        #expect(scratch.read("dest/a/keep.txt") == "keep")
        #expect(noTemporaries(scratch.sub("dest")))
    }

    /// NFC and NFD spellings are different names; the duplicate check compares bytes, so with
    /// `overwrite: false` they are not mistaken for duplicates before extraction starts.
    @Test func duplicateCheckComparesBytes() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("x.zip"), [RawEntry(name: "caf\u{E9}", contents: "1"), RawEntry(name: "cafe\u{301}", contents: "2")])
        let status = Zip().unzipFile(source: scratch.sub("x.zip"), destination: scratch.sub("d"), overwrite: false)
        #if os(Linux)
        #expect(status == .ZipSuccess)
        #else
        // APFS treats the two as the same name: the second create fails closed.
        #expect(status == .ZipSuccess || status == .ZipCannotOverwrite)
        #endif
    }

    @Test func fileWhereDirectoryIsNeededFails() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a", contents: "file"), RawEntry(name: "a/b", contents: "x")])
        // 3.x reported success here and silently dropped `a/b`.
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
    }

    @Test func destinationThatIsAFileFails() throws {
        let scratch = try Scratch()
        try scratch.write("dest", "not a directory")
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "x")])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipFail)
    }

    @Test func corruptArchivesFailCleanly() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        try scratch.write("src/a.txt", String(repeating: "abcdefgh", count: 4096))
        #expect(Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"), overwrite: true) == .ZipSuccess)
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip"))))

        // Truncations and single-byte corruptions at every 7th offset: never a crash, and a
        // status that is either success (harmless byte) or a failure.
        for cut in stride(from: 0, to: good.count, by: 7) {
            for variant in 0..<2 {
                var bytes = good
                if variant == 0 { bytes = Array(bytes.prefix(cut)) } else { bytes[cut] ^= 0x5A }
                try Data(bytes).write(to: URL(fileURLWithPath: scratch.sub("bad.zip")))
                let status = Zip().unzipFile(source: scratch.sub("bad.zip"), destination: scratch.sub("out/\(cut)-\(variant)"), overwrite: true)
                #expect([.ZipSuccess, .UnzipFail, .UnzipUnsafePath, .ZipCannotOverwrite, .UnzipLimitExceeded, .UnzipIncorrectPassword].contains(status))
            }
        }
    }

    @Test func failedZipLeavesExistingArchiveAlone() throws {
        let scratch = try Scratch()
        try scratch.write("old.txt", "old")
        #expect(Zip().zipFiles(paths: [scratch.sub("old.txt")], zipFilePath: scratch.sub("a.zip"), overwrite: true) == .ZipSuccess)
        let before = try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip")))
        try scratch.makeDirectory("x")
        try scratch.makeDirectory("y")
        try scratch.write("x/same.txt", "1")
        try scratch.write("y/same.txt", "2")
        // Two top-level files with the same entry name: refused, archive untouched, no temp left.
        #expect(Zip().zipFiles(paths: [scratch.sub("x/same.txt"), scratch.sub("y/same.txt")],
                               zipFilePath: scratch.sub("a.zip"), overwrite: true) == .ZipFail)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip"))) == before)
        #expect(!scratch.allPaths().contains { $0.hasSuffix(".tmp") })
    }

    @Test func archiveIsNotZippedIntoItself() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("tree")
        try scratch.write("tree/a.txt", "a")
        let zipPath = scratch.sub("tree/self.zip")
        #expect(Zip().zipFiles(paths: [scratch.sub("tree")], zipFilePath: zipPath, overwrite: true) == .ZipSuccess)
        #expect(Zip().zipFiles(paths: [scratch.sub("tree")], zipFilePath: zipPath, overwrite: true) == .ZipSuccess)
        #expect(try entryNames(of: zipPath) == ["tree/", "tree/a.txt"])
    }

    @Test func concurrentZipAndUnzip() async throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        try scratch.write("src/a.txt", String(repeating: "x", count: 50_000))
        try zipCryptoFixture.write(to: URL(fileURLWithPath: scratch.sub("enc.zip")))
        let root = scratch.path
        let zip = Zip() // one shared instance
        let results = await withTaskGroup(of: ZipStatus.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let path = "\(root)/c\(i).zip"
                    let z = zip.zipFiles(paths: ["\(root)/src"], zipFilePath: path, overwrite: true)
                    guard z == .ZipSuccess else { return z }
                    let u = zip.unzipFile(source: path, destination: "\(root)/out\(i)", overwrite: true)
                    guard u == .ZipSuccess else { return u }
                    return zip.unzipFile(source: "\(root)/enc.zip", destination: "\(root)/enc\(i)", overwrite: true, password: "pässword")
                }
            }
            var all = [ZipStatus]()
            for await r in group { all.append(r) }
            return all
        }
        #expect(results == Array(repeating: .ZipSuccess, count: 8))
    }
}

/// The 3.x `zipFiles` signature, called through a protocol so the tests can exercise the
/// deprecated overload without a deprecation warning.
protocol LegacyZipping {
    func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool, password: String?) -> ZipStatus
}
extension Zip: LegacyZipping {}
