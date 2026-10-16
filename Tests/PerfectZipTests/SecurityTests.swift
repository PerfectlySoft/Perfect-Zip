import Testing
import Foundation
@testable import PerfectZip

/// Malicious-archive (Zip Slip) tests. Archives are built in the test with minizip's zip API,
/// which writes whatever entry name it is given.
@Suite struct SecurityTests {

    /// Extracts `entries` into `<scratch>/out/dest` and returns the status. Anything written
    /// outside `dest` shows up in `scratch.allPaths()`.
    private func extract(_ entries: [RawEntry], in scratch: Scratch, overwrite: Bool = true) throws -> ZipStatus {
        try scratch.makeDirectory("out")
        try makeArchive(at: scratch.sub("evil.zip"), entries)
        return Zip().unzipFile(source: scratch.sub("evil.zip"), destination: scratch.sub("out/dest"), overwrite: overwrite)
    }

    @Test(arguments: [
        "../evil.txt",
        "../../evil.txt",
        "..\\..\\evil.txt",
        "a/../../evil.txt",
        "a\\..\\..\\evil.txt",
        "a/../b.txt",           // stays inside, but any `..` component is refused
        "/tmp/perfectzip-evil.txt",
        "\\tmp\\perfectzip-evil.txt",
        "C:/evil.txt",
        "C:evil.txt",
        "./../evil.txt",
    ])
    func rejectsHostileNames(name: String) throws {
        let scratch = try Scratch()
        let status = try extract([RawEntry(name: "good.txt", contents: "ok"), RawEntry(name: name, contents: "pwned")],
                                 in: scratch)
        #expect(status == .UnzipUnsafePath)
        // Fails closed: names are checked before anything is written, so not even the good
        // entry (or the destination directory) exists.
        #expect(scratch.allPaths() == ["evil.zip", "out"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/perfectzip-evil.txt"))
    }

    @Test func rejectsEmbeddedNUL() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("evil.zip"), [RawEntry(nameBytes: Array("safe.txt\0.sh".utf8), contents: [1])])
        #expect(try entryNames(of: scratch.sub("evil.zip")) == ["safe.txt\0.sh"])
        let status = Zip().unzipFile(source: scratch.sub("evil.zip"), destination: scratch.sub("dest"), overwrite: true)
        #expect(status == .UnzipUnsafePath)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("dest")))
    }

    /// With the UTF-8 flag set, invalid UTF-8 is refused rather than guessed at.
    @Test func rejectsInvalidUTF8WithFlag() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("bad.zip"), [RawEntry(nameBytes: [0x61, 0xFF, 0x62], contents: [1], utf8Flag: true)])
        #expect(Zip().unzipFile(source: scratch.sub("bad.zip"), destination: scratch.sub("dest"), overwrite: true) == .UnzipUnsafePath)
    }

    @Test func rejectsEmptyName() throws {
        let scratch = try Scratch()
        #expect(try extract([RawEntry(name: "/")], in: scratch) == .UnzipUnsafePath)
    }

    /// An archive that first stores a symlink entry and then writes "through" it. Symlink
    /// entries are extracted as plain files, so the second entry cannot get out.
    @Test func symlinkEntryThenWriteThroughIt() throws {
        let scratch = try Scratch()
        let outside = try scratch.makeDirectory("outside")
        let status = try extract([
            RawEntry(name: "link", contents: outside, unixMode: 0o120777),
            RawEntry(name: "link/evil.txt", contents: "pwned"),
        ], in: scratch)
        #expect(status == .UnzipFail) // `link` is a regular file, so `link/` cannot be a directory
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
        let attrs = try FileManager.default.attributesOfItem(atPath: scratch.sub("out/dest/link"))
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect(scratch.read("out/dest/link") == outside)
    }

    @Test func preexistingSymlinkedDirectoryInDestination() throws {
        let scratch = try Scratch()
        let outside = try scratch.makeDirectory("outside")
        let dest = try scratch.makeDirectory("dest")
        try FileManager.default.createSymbolicLink(atPath: dest + "/link", withDestinationPath: outside)
        try makeArchive(at: scratch.sub("evil.zip"), [RawEntry(name: "link/evil.txt", contents: "pwned")])

        let status = Zip().unzipFile(source: scratch.sub("evil.zip"), destination: dest, overwrite: true)
        #expect(status == .UnzipUnsafePath)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }

    @Test func preexistingSymlinkedFileInDestination() throws {
        let scratch = try Scratch()
        try scratch.write("target.txt", "original")
        let dest = try scratch.makeDirectory("dest")
        try FileManager.default.createSymbolicLink(atPath: dest + "/file.txt", withDestinationPath: scratch.sub("target.txt"))
        try makeArchive(at: scratch.sub("evil.zip"), [RawEntry(name: "file.txt", contents: "pwned")])

        let status = Zip().unzipFile(source: scratch.sub("evil.zip"), destination: dest, overwrite: true)
        #expect(status == .UnzipUnsafePath)
        #expect(scratch.read("target.txt") == "original")
        let attrs = try FileManager.default.attributesOfItem(atPath: dest + "/file.txt")
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    /// `overwrite: true` replaces an existing file instead of truncating it, so a hard link in
    /// the destination to a file outside it is broken, not written through.
    @Test func preexistingHardLinkInDestination() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("outside")
        try scratch.write("outside/victim.txt", "original")
        let dest = try scratch.makeDirectory("dest")
        try FileManager.default.linkItem(atPath: scratch.sub("outside/victim.txt"), toPath: dest + "/a.txt")
        try makeArchive(at: scratch.sub("a.zip"), [RawEntry(name: "a.txt", contents: "pwned")])

        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: dest, overwrite: true) == .ZipSuccess)
        #expect(scratch.read("outside/victim.txt") == "original")
        #expect(scratch.read("dest/a.txt") == "pwned")
        let links = try FileManager.default.attributesOfItem(atPath: scratch.sub("outside/victim.txt"))[.referenceCount] as? Int
        #expect(links == 1)
    }

    @Test func depthLimit() throws {
        let scratch = try Scratch()
        let ok = Array(repeating: "d", count: EntryPath.maxDepth - 1).joined(separator: "/") + "/leaf.txt"
        let deep = Array(repeating: "d", count: EntryPath.maxDepth).joined(separator: "/") + "/leaf.txt"
        try makeArchive(at: scratch.sub("ok.zip"), [RawEntry(name: ok, contents: "x")])
        try makeArchive(at: scratch.sub("deep.zip"), [RawEntry(name: deep, contents: "x")])
        #expect(Zip().unzipFile(source: scratch.sub("ok.zip"), destination: scratch.sub("d1"), overwrite: true) == .ZipSuccess)
        #expect(Zip().unzipFile(source: scratch.sub("deep.zip"), destination: scratch.sub("d2"), overwrite: true) == .UnzipUnsafePath)
        #expect(!FileManager.default.fileExists(atPath: scratch.sub("d2")))
    }

    /// Directory entries nested one level deeper each time (`d/`, `d/d/`, ...) used to cost a
    /// walk from the root per entry; the directory cache makes this linear.
    @Test(.timeLimit(.minutes(1)))
    func deepNestingIsFast() throws {
        let scratch = try Scratch()
        var entries = (1..<EntryPath.maxDepth).map { RawEntry(name: String(repeating: "d/", count: $0)) }
        entries.append(RawEntry(name: String(repeating: "d/", count: EntryPath.maxDepth - 1) + "leaf.txt", contents: "leaf"))
        try makeArchive(at: scratch.sub("deep.zip"), entries)
        let start = Date()
        #expect(Zip().unzipFile(source: scratch.sub("deep.zip"), destination: scratch.sub("d"), overwrite: true) == .ZipSuccess)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(scratch.read("d/" + String(repeating: "d/", count: EntryPath.maxDepth - 1) + "leaf.txt") == "leaf")
    }

    /// Entries in many sibling directories, revisiting earlier ones, land where they belong.
    @Test func directoryCacheKeepsEntriesApart() throws {
        let scratch = try Scratch()
        try makeArchive(at: scratch.sub("a.zip"), [
            RawEntry(name: "a/b/1.txt", contents: "1"), RawEntry(name: "a/2.txt", contents: "2"),
            RawEntry(name: "a/b/c/3.txt", contents: "3"), RawEntry(name: "x/4.txt", contents: "4"),
            RawEntry(name: "a/b/5.txt", contents: "5"), RawEntry(name: "6.txt", contents: "6"),
            RawEntry(name: "caf\u{E9}/7.txt", contents: "7"), RawEntry(name: "cafe\u{301}/8.txt", contents: "8"),
        ])
        #expect(Zip().unzipFile(source: scratch.sub("a.zip"), destination: scratch.sub("d"), overwrite: true) == .ZipSuccess)
        for (path, text) in [("a/b/1.txt", "1"), ("a/2.txt", "2"), ("a/b/c/3.txt", "3"), ("x/4.txt", "4"),
                             ("a/b/5.txt", "5"), ("6.txt", "6")] {
            #expect(scratch.read("d/" + path) == text, "\(path)")
        }
        // NFC and NFD spellings are different names on Linux; on macOS (APFS) they may be the
        // same directory. Either way both files are extracted.
        let all = (try FileManager.default.subpathsOfDirectory(atPath: scratch.sub("d"))).filter { $0.hasSuffix(".txt") }
        #expect(all.count == 8)
    }

    /// The destination itself may be reached through a symlink; it is resolved first.
    @Test func symlinkedDestinationIsAllowed() throws {
        let scratch = try Scratch()
        let real = try scratch.makeDirectory("real")
        try FileManager.default.createSymbolicLink(atPath: scratch.sub("alias"), withDestinationPath: real)
        try makeArchive(at: scratch.sub("ok.zip"), [RawEntry(name: "a/b.txt", contents: "hi")])
        let status = Zip().unzipFile(source: scratch.sub("ok.zip"), destination: scratch.sub("alias"), overwrite: true)
        #expect(status == .ZipSuccess)
        #expect(scratch.read("real/a/b.txt") == "hi")
    }

    @Test func macOSMetadataIsSkipped() throws {
        let scratch = try Scratch()
        let status = try extract([
            RawEntry(name: "__MACOSX/"), RawEntry(name: "__MACOSX/._a.txt", contents: "junk"),
            RawEntry(name: "a.txt", contents: "a"),
        ], in: scratch)
        #expect(status == .ZipSuccess)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: scratch.sub("out/dest"))) == ["a.txt"])
    }

    // MARK: - Entry names written by zipFiles

    @Test func zipEntryNamesNeverEscape() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("tree/sub")
        try scratch.write("tree/sub/f.txt", "f")
        // `tree/sub/..` used to become entries named `../...`. Every spelling of the same
        // directory gives the same, safe names.
        for spelling in ["tree/sub/..", "tree/./sub/../", "tree/sub/../../tree", "tree//sub/.."] {
            let archive = scratch.sub("a.zip")
            let status = Zip().zipFiles(paths: [scratch.sub(spelling)], zipFilePath: archive, overwrite: true)
            #expect(status == .ZipSuccess, "\(spelling)")
            let names = try entryNames(of: archive)
            #expect(names == ["tree/", "tree/sub/", "tree/sub/f.txt"], "\(spelling)")
            for name in names {
                #expect(!name.split(separator: "/").contains(".."), "\(spelling): \(name)")
                #expect(EntryPath.validate(Array(name.utf8)) != .unsafe)
            }
        }
    }

    @Test func zipSkipsSymlinksInsideTreeAndLoops() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("tree")
        try scratch.write("tree/f.txt", "f")
        try scratch.makeDirectory("secret")
        try scratch.write("secret/key.txt", "secret")
        try FileManager.default.createSymbolicLink(atPath: scratch.sub("tree/out"), withDestinationPath: scratch.sub("secret"))
        try FileManager.default.createSymbolicLink(atPath: scratch.sub("tree/keylink"), withDestinationPath: scratch.sub("secret/key.txt"))
        try FileManager.default.createSymbolicLink(atPath: scratch.sub("tree/loop"), withDestinationPath: scratch.sub("tree"))

        let status = Zip().zipFiles(paths: [scratch.sub("tree")], zipFilePath: scratch.sub("a.zip"), overwrite: true)
        #expect(status == .ZipSuccess)
        #expect(try entryNames(of: scratch.sub("a.zip")) == ["tree/", "tree/f.txt"])
    }

    @Test func zipFollowsTopLevelSymlinkedDirectory() throws {
        let scratch = try Scratch()
        try scratch.makeDirectory("real")
        try scratch.write("real/f.txt", "f")
        try FileManager.default.createSymbolicLink(atPath: scratch.sub("alias"), withDestinationPath: scratch.sub("real"))
        let status = Zip().zipFiles(paths: [scratch.sub("alias")], zipFilePath: scratch.sub("a.zip"), overwrite: true)
        #expect(status == .ZipSuccess)
        #expect(try entryNames(of: scratch.sub("a.zip")) == ["alias/", "alias/f.txt"])
    }

    // MARK: - Name validation

    @Test func validateNames() {
        #expect(EntryPath.validate(Array("a/b.txt".utf8)) == .file(["a", "b.txt"]))
        #expect(EntryPath.validate(Array("a\\b\\".utf8)) == .directory(["a", "b"]))
        #expect(EntryPath.validate(Array("./a//b".utf8)) == .file(["a", "b"]))
        #expect(EntryPath.validate(Array("..foo/bar..".utf8)) == .file(["..foo", "bar.."]))
        #expect(EntryPath.validate(Array("..".utf8)) == .unsafe)
        #expect(EntryPath.validate(Array("./".utf8)) == .unsafe)
        #expect(EntryPath.validate([UInt8]()) == .unsafe)
        #expect(EntryPath.isContained(["a", "b"], in: "/x/dest"))
        #expect(!EntryPath.isContained(["..", "b"], in: "/x/dest"))
        #expect(!EntryPath.isContained([".."], in: "/x/dest"))
    }
}
