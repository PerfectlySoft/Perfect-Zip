import Testing
import Foundation
@testable import PerfectZip

/// Interoperability with other zip implementations, both directions. Each test is skipped
/// when its tool is not installed (`ditto` is macOS-only; the Linux CI image may lack
/// `zip`/`unzip`/`bsdtar`).
@Suite struct InteropTests {

    /// A tree with nesting, an empty directory, an empty file, a non-ASCII name, an executable
    /// and a file large enough to span several 64 KiB buffers.
    private func makeTree(_ scratch: Scratch) throws -> String {
        try scratch.makeDirectory("tree/sub/deeper")
        try scratch.makeDirectory("tree/empty")
        try scratch.write("tree/a.txt", "alpha\n")
        try scratch.write("tree/sub/café ü.txt", "unicode name\n")
        try scratch.write("tree/sub/deeper/empty.txt", "")
        try scratch.write("tree/run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.sub("tree/run.sh"))
        var rng = SystemRandomNumberGenerator()
        var big = [UInt8]()
        for i in 0..<300_000 { big.append(i % 3 == 0 ? UInt8.random(in: 0...255, using: &rng) : UInt8(i % 251)) }
        try scratch.writeBytes("tree/sub/big.bin", big)
        return scratch.sub("tree")
    }

    /// Relative path to contents (nil for directories), ignoring macOS metadata.
    private func snapshot(_ root: String) throws -> [String: [UInt8]?] {
        var result = [String: [UInt8]?]()
        let fm = FileManager.default
        for rel in try fm.subpathsOfDirectory(atPath: root) where !rel.contains("__MACOSX") && !rel.hasSuffix(".DS_Store") {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: root + "/" + rel, isDirectory: &isDir)
            result[rel.precomposedStringWithCanonicalMapping] = isDir.boolValue ? .some(nil) : [UInt8](try Data(contentsOf: URL(fileURLWithPath: root + "/" + rel)))
        }
        return result
    }

    private func writeScript(_ scratch: Scratch, _ name: String, _ body: String) throws -> String {
        try scratch.write(name, body)
        return scratch.sub(name)
    }

    // MARK: PerfectZip writes, others read

    @Test(.enabled(if: toolExists("unzip")))
    func unzipTestsOurArchive() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        #expect(Zip().zipFiles(paths: [tree], zipFilePath: scratch.sub("ours.zip"), overwrite: true) == .ZipSuccess)
        let t = run("unzip", ["-t", scratch.sub("ours.zip")])
        #expect(t?.status == 0, "\(t?.output ?? "")")
        let x = run("unzip", ["-q", scratch.sub("ours.zip"), "-d", scratch.sub("out")])
        #expect(x?.status == 0, "\(x?.output ?? "")")
        #expect(try snapshot(scratch.sub("out/tree")) == snapshot(tree))
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.sub("out/tree/run.sh"))[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test(.enabled(if: toolExists("ditto")))
    func dittoExtractsOurArchive() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        #expect(Zip().zipFiles(paths: [tree], zipFilePath: scratch.sub("ours.zip"), overwrite: true) == .ZipSuccess)
        let x = run("ditto", ["-x", "-k", scratch.sub("ours.zip"), scratch.sub("out")])
        #expect(x?.status == 0, "\(x?.output ?? "")")
        #expect(try snapshot(scratch.sub("out/tree")) == snapshot(tree))
    }

    @Test(.enabled(if: toolExists("bsdtar")))
    func bsdtarExtractsOurArchive() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        #expect(Zip().zipFiles(paths: [tree], zipFilePath: scratch.sub("ours.zip"), overwrite: true) == .ZipSuccess)
        try scratch.makeDirectory("out")
        let x = run("bsdtar", ["-xf", scratch.sub("ours.zip"), "-C", scratch.sub("out")])
        #expect(x?.status == 0, "\(x?.output ?? "")")
        #expect(try snapshot(scratch.sub("out/tree")) == snapshot(tree))
    }

    @Test(.enabled(if: toolExists("python3")))
    func pythonReadsOurArchive() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        #expect(Zip().zipFiles(paths: [tree], zipFilePath: scratch.sub("ours.zip"), overwrite: true) == .ZipSuccess)
        let script = try writeScript(scratch, "check.py", """
            import zipfile, sys, os
            z = zipfile.ZipFile(sys.argv[1])
            assert z.testzip() is None
            names = sorted(z.namelist())
            print("\\n".join(names))
            for i in z.infolist():
                assert i.create_system == 3, i.create_system
                if not i.is_dir():
                    assert z.read(i) == open(os.path.join(sys.argv[2], i.filename), "rb").read(), i.filename
            """)
        let r = run("python3", ["-I", script, scratch.sub("ours.zip"), scratch.path])
        #expect(r?.status == 0, "\(r?.output ?? "")")
        #expect(r?.output.contains("tree/sub/café ü.txt") == true)
        #expect(r?.output.contains("tree/empty/") == true)
    }

    // MARK: Others write, PerfectZip reads

    private func expectWeRead(_ archive: String, matches tree: String, in scratch: Scratch, root: String = "tree",
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dest = scratch.sub("ours-\(UUID().uuidString)")
        let status = Zip().unzipFile(source: archive, destination: dest, overwrite: true)
        #expect(status == .ZipSuccess, sourceLocation: sourceLocation)
        #expect(try snapshot(dest + "/" + root) == snapshot(tree), sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: toolExists("zip")))
    func weReadInfoZip() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        let r = run("zip", ["-q", "-r", scratch.sub("infozip.zip"), "tree"], cwd: scratch.path)
        #expect(r?.status == 0, "\(r?.output ?? "")")
        try expectWeRead(scratch.sub("infozip.zip"), matches: tree, in: scratch)
        // Info-ZIP streaming mode (`-fd` forces data descriptors) from stdin is not portable;
        // `zip -0` gives stored entries.
        _ = run("zip", ["-q", "-r", "-0", scratch.sub("stored.zip"), "tree"], cwd: scratch.path)
        try expectWeRead(scratch.sub("stored.zip"), matches: tree, in: scratch)
    }

    @Test(.enabled(if: toolExists("zip")))
    func weReadInfoZipPassword() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        let r = run("zip", ["-q", "-r", "-P", "zip-pw", scratch.sub("enc.zip"), "tree"], cwd: scratch.path)
        #expect(r?.status == 0, "\(r?.output ?? "")")
        let dest = scratch.sub("dest")
        #expect(Zip().unzipFile(source: scratch.sub("enc.zip"), destination: dest, overwrite: true, password: "zip-pw") == .ZipSuccess)
        #expect(try snapshot(dest + "/tree") == snapshot(tree))
        #expect(Zip().unzipFile(source: scratch.sub("enc.zip"), destination: scratch.sub("d2"), overwrite: true, password: "nope") == .UnzipIncorrectPassword)
    }

    @Test(.enabled(if: toolExists("ditto")))
    func weReadDitto() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        for flags in [["--norsrc"], ["--sequesterRsrc"]] {
            let archive = scratch.sub("ditto\(flags[0]).zip")
            let r = run("ditto", ["-c", "-k", "--keepParent"] + flags + [tree, archive])
            #expect(r?.status == 0, "\(r?.output ?? "")")
            try expectWeRead(archive, matches: tree, in: scratch)
        }
    }

    @Test(.enabled(if: toolExists("bsdtar")))
    func weReadBsdtar() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        for options in [[], ["--options", "zip:compression=store"]] {
            let archive = scratch.sub("bsdtar\(options.count).zip")
            let r = run("bsdtar", ["--format", "zip"] + options + ["-cf", archive, "tree"], cwd: scratch.path)
            #expect(r?.status == 0, "\(r?.output ?? "")")
            try expectWeRead(archive, matches: tree, in: scratch)
        }
    }

    /// Python's zipfile: stored, deflated, forced Zip64 local headers, data descriptors (written
    /// when the output is not seekable), and an archive comment.
    @Test(.enabled(if: toolExists("python3")))
    func weReadPython() throws {
        let scratch = try Scratch()
        let tree = try makeTree(scratch)
        let script = try writeScript(scratch, "make.py", """
            import zipfile, sys, os
            root, out = sys.argv[1], sys.argv[2]
            def files():
                for d, dirs, fs in os.walk(root):
                    rel = os.path.relpath(d, os.path.dirname(root))
                    yield rel + "/", None
                    for f in fs:
                        yield os.path.join(rel, f), os.path.join(d, f)
            class Unseekable:
                def __init__(self, f): self.f = f
                def write(self, b): return self.f.write(b)
                def flush(self): self.f.flush()
                def tell(self): raise OSError("unseekable")
                def seek(self, *a): raise OSError("unseekable")
            for name, method, zip64, stream in [("stored", zipfile.ZIP_STORED, False, False),
                                                ("deflated", zipfile.ZIP_DEFLATED, False, False),
                                                ("zip64", zipfile.ZIP_DEFLATED, True, False),
                                                ("stream", zipfile.ZIP_DEFLATED, False, True)]:
                path = os.path.join(out, name + ".zip")
                raw = open(path, "wb")
                with zipfile.ZipFile(Unseekable(raw) if stream else raw, "w", method) as z:
                    z.comment = b"made by python " + name.encode()
                    for arc, src in files():
                        if src is None:
                            z.writestr(zipfile.ZipInfo(arc), b"")
                        else:
                            with z.open(arc, "w", force_zip64=zip64) as w, open(src, "rb") as r:
                                w.write(r.read())
                raw.close()
            """)
        let r = run("python3", ["-I", script, tree, scratch.path])
        #expect(r?.status == 0, "\(r?.output ?? "")")
        for name in ["stored", "deflated", "zip64", "stream"] {
            try expectWeRead(scratch.sub("\(name).zip"), matches: tree, in: scratch)
        }
        // The stream variant really used data descriptors, and zip64 really has Zip64 extras.
        let stream = try scratch.bytes("stream.zip")
        #expect(stream[6] & 0x08 != 0)
        let z64 = try scratch.bytes("zip64.zip")
        var zip64Locals = 0
        var at = 0
        while let i = find(le32(Signature.localHeader), in: z64, from: at) {
            // Python keeps the real 32-bit sizes and adds a 16-byte Zip64 extra field.
            let nameLength = Int(z64[i + 26]) | Int(z64[i + 27]) << 8
            if Array(z64[i + 30 + nameLength..<i + 34 + nameLength]) == [0x01, 0x00, 0x10, 0x00] { zip64Locals += 1 }
            at = i + 4
        }
        #expect(zip64Locals >= 5) // every file entry
    }
}
