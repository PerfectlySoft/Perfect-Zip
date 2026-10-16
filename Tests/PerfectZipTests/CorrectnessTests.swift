import Testing
import Foundation
@testable import PerfectZip

@Suite struct CorrectnessTests {

    private func roundTrip(_ scratch: Scratch, password: String?, unzipPassword: String) throws -> ZipStatus {
        try scratch.makeDirectory("src/empty")
        try scratch.write("src/a.txt", String(repeating: "hello zip ", count: 10_000))
        let zipped = Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"),
                                    overwrite: true, password: password)
        #expect(zipped == .ZipSuccess)
        return Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("dest"),
                               overwrite: true, password: unzipPassword)
    }

    @Test func passwordRoundTrip() throws {
        let scratch = try Scratch()
        #expect(try roundTrip(scratch, password: "s3cret", unzipPassword: "s3cret") == .ZipSuccess)
        #expect(scratch.read("dest/src/a.txt") == scratch.read("src/a.txt"))
    }

    /// 3.x ignored the `password` argument of `unzipFile`, so encrypted archives produced
    /// garbage or failed. Without the password, or with a wrong one, nothing is left behind.
    @Test(arguments: ["", "wrong"])
    func passwordMissingOrWrong(password: String) throws {
        let scratch = try Scratch()
        #expect(try roundTrip(scratch, password: "s3cret", unzipPassword: password) == .UnzipFail)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("dest/src/a.txt")))
    }

    @Test func emptyDirectoriesAreKept() throws {
        let scratch = try Scratch()
        #expect(try roundTrip(scratch, password: nil, unzipPassword: "") == .ZipSuccess)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: scratch.sub("dest/src/empty"), isDirectory: &isDir) && isDir.boolValue)
    }

    /// The bundled MiniZip 1.1 fork cannot open an archive with no entries (fixed upstream in
    /// zlib 1.3's minizip), so this reports UnzipFail for now.
    @Test func emptyArchive() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("empty.zip"), [])
        withKnownIssue("MiniZip 1.1 fork rejects archives with no entries") {
            #expect(Zip().unzipFile(source: scratch.sub("empty.zip"), destination: scratch.sub("dest"), overwrite: true) == .ZipSuccess)
        }
    }

    @Test func permissionsAndTimestampsSurvive() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        try scratch.write("src/run.sh", "#!/bin/sh\n")
        let fm = FileManager.default
        let when = Date(timeIntervalSince1970: 1_600_000_000) // even second: DOS time has 2 s steps
        try fm.setAttributes([.posixPermissions: 0o750, .modificationDate: when], ofItemAtPath: scratch.sub("src/run.sh"))

        #expect(Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"), overwrite: true, password: nil) == .ZipSuccess)
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
        #expect(Zip().zipFiles(paths: [scratch.sub("src")], zipFilePath: scratch.sub("a.zip"), overwrite: true, password: nil) == .ZipSuccess)
        let good = [UInt8](try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip"))))

        // Truncations and single-byte corruptions at every 7th offset: never a crash, and a
        // status that is either success (harmless byte) or a failure.
        for cut in stride(from: 0, to: good.count, by: 7) {
            for variant in 0..<2 {
                var bytes = good
                if variant == 0 { bytes = Array(bytes.prefix(cut)) } else { bytes[cut] ^= 0x5A }
                try Data(bytes).write(to: URL(fileURLWithPath: scratch.sub("bad.zip")))
                let status = Zip().unzipFile(source: scratch.sub("bad.zip"), destination: scratch.sub("out/\(cut)-\(variant)"), overwrite: true)
                #expect([.ZipSuccess, .UnzipFail, .UnzipUnsafePath, .ZipCannotOverwrite].contains(status))
            }
        }
    }

    @Test func failedZipLeavesExistingArchiveAlone() throws {
        let scratch = try Scratch()
        try scratch.write("old.txt", "old")
        #expect(Zip().zipFiles(paths: [scratch.sub("old.txt")], zipFilePath: scratch.sub("a.zip"), overwrite: true, password: nil) == .ZipSuccess)
        let before = try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip")))
        try scratch.makeDirectory("x")
        try scratch.makeDirectory("y")
        try scratch.write("x/same.txt", "1")
        try scratch.write("y/same.txt", "2")
        // Two top-level files with the same entry name: refused, archive untouched, no temp left.
        #expect(Zip().zipFiles(paths: [scratch.sub("x/same.txt"), scratch.sub("y/same.txt")],
                               zipFilePath: scratch.sub("a.zip"), overwrite: true, password: nil) == .ZipFail)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.sub("a.zip"))) == before)
        #expect(!scratch.allPaths().contains { $0.hasSuffix(".tmp") })
    }

    @Test func archiveIsNotZippedIntoItself() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("tree")
        try scratch.write("tree/a.txt", "a")
        let zipPath = scratch.sub("tree/self.zip")
        #expect(Zip().zipFiles(paths: [scratch.sub("tree")], zipFilePath: zipPath, overwrite: true, password: nil) == .ZipSuccess)
        #expect(Zip().zipFiles(paths: [scratch.sub("tree")], zipFilePath: zipPath, overwrite: true, password: nil) == .ZipSuccess)
        #expect(try entryNames(of: zipPath) == ["tree/", "tree/a.txt"])
    }

    @Test func concurrentEncryptedZips() async throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("src")
        try scratch.write("src/a.txt", String(repeating: "x", count: 50_000))
        let root = scratch.path
        let results = await withTaskGroup(of: ZipStatus.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let zip = "\(root)/c\(i).zip"
                    let z = Zip().zipFiles(paths: ["\(root)/src"], zipFilePath: zip, overwrite: true, password: "pw")
                    guard z == .ZipSuccess else { return z }
                    return Zip().unzipFile(source: zip, destination: "\(root)/out\(i)", overwrite: true, password: "pw")
                }
            }
            var all = [ZipStatus]()
            for await r in group { all.append(r) }
            return all
        }
        #expect(results == Array(repeating: .ZipSuccess, count: 8))
    }
}
