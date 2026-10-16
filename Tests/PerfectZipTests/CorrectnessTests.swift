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
        #expect((attrs[.posixPermissions] as? Int) == 0o750)
        #expect((attrs[.modificationDate] as? Date) == when)
    }

    @Test func setuidBitsAreNotRestored() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "x", contents: "x", unixMode: 0o104755)])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        let attrs = try FileManager.default.attributesOfItem(atPath: scratch.sub("dest/x"))
        #expect((attrs[.posixPermissions] as? Int) == 0o755)
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
