import Foundation
@testable import PerfectZip

/// A scratch directory removed when the value is released.
final class Scratch {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfectZipTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func sub(_ name: String) -> String { url.appendingPathComponent(name).path }

    @discardableResult
    func makeDirectory(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: sub(name), withIntermediateDirectories: true)
        return sub(name)
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: sub(name)))
    }

    func writeBytes(_ name: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: sub(name)))
    }

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: sub(name)).map { String(decoding: $0, as: UTF8.self) }
    }

    func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: sub(name))))
    }

    /// Every path below the scratch directory, relative to it.
    func allPaths() -> Set<String> {
        Set((try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? [])
    }
}

/// An entry for ``makeArchive(at:_:)``. The archive is written by PerfectZip's internal
/// writer, which takes the name as raw bytes, so tests can plant any name an attacker could.
struct RawEntry {
    var nameBytes: [UInt8]
    var contents: [UInt8] = []
    /// Unix `st_mode` to store in the external attributes.
    var unixMode: UInt32? = nil
    var isDirectory = false
    var style: ArchiveWriter.SizeStyle = .patched
    var utf8Flag: Bool? = nil

    init(name: String, contents: String = "", unixMode: UInt32? = nil,
         style: ArchiveWriter.SizeStyle = .patched) {
        self.nameBytes = Array(name.utf8)
        self.contents = Array(contents.utf8)
        self.unixMode = unixMode
        self.isDirectory = name.hasSuffix("/")
        self.style = style
    }

    init(nameBytes: [UInt8], contents: [UInt8] = [], utf8Flag: Bool? = nil) {
        self.nameBytes = nameBytes
        self.contents = contents
        self.utf8Flag = utf8Flag
    }
}

func makeArchive(at path: String, _ entries: [RawEntry]) throws {
    let writer = try ArchiveWriter(path: path)
    for entry in entries {
        var offset = 0
        let data = entry.contents
        try writer.add(name: entry.nameBytes, isDirectory: entry.isDirectory, unixMode: entry.unixMode,
                       modified: 1_704_110_400, sizeHint: UInt64(data.count), style: entry.style,
                       utf8Flag: entry.utf8Flag,
                       source: entry.isDirectory ? nil : { buffer, size in
                           let n = min(size, data.count - offset)
                           data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
                           offset += n
                           return n
                       })
    }
    try writer.finish()
}

/// The decoded entry names of an archive, in order, read with PerfectZip's reader.
func entryNames(of path: String, limits: ZipLimits = .unlimited) throws -> [String] {
    try ArchiveReader(path: path).entries(limits: limits).map { $0.name ?? "<invalid>" }
}

/// Offset of the first occurrence of `pattern` at or after `from`.
func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int = 0) -> Int? {
    guard bytes.count >= pattern.count else { return nil }
    var i = from
    while i + pattern.count <= bytes.count {
        if bytes[i] == pattern[0] && Array(bytes[i..<i + pattern.count]) == pattern { return i }
        i += 1
    }
    return nil
}

func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

/// Runs a tool and returns its exit status and combined output. nil if it is not installed.
@discardableResult
func run(_ tool: String, _ args: [String], cwd: String? = nil) -> (status: Int32, output: String)? {
    let candidates = tool.hasPrefix("/") ? [tool] : ["/usr/bin/\(tool)", "/bin/\(tool)", "/usr/local/bin/\(tool)", "/opt/homebrew/bin/\(tool)"]
    guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    #if os(Linux)
    // Info-ZIP on Linux mangles non-ASCII names (`#U0301`) unless the locale is UTF-8.
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C.UTF-8"
    p.environment = environment
    #endif
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func toolExists(_ tool: String) -> Bool {
    ["/usr/bin/\(tool)", "/bin/\(tool)", "/usr/local/bin/\(tool)", "/opt/homebrew/bin/\(tool)"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }
}

/// `deflated.txt` (1800 bytes) and `stored.txt` ("stored secret\n"), encrypted by Info-ZIP
/// `zip -P 'pässword'` (ZipCrypto, with data descriptors), dated 2024-01-02 12:30 UTC.
let zipCryptoFixture = Data(base64Encoded: """
UEsDBBQACQAIAMAzIljmw5VkSgAAAAgHAAAMAAAAZGVmbGF0ZWQudHh0pcX3wNQI9ZUN3Gv/XZiQstb8phRiHpng40JZsLrKlSW4s7VRqbFygpuDevGhGiMG8imfb929aCPfqXJFIAzsAAX6Xfni1FsacVhQSwcI5sOVZEoAAAAIBwAAUEsDBAoACQAAAMAzIlg48cBxGgAAAA4AAAAKAAAAc3RvcmVkLnR4dCmf++C2+NWfHjVI6w+MejN+cXFrAcIiT2R9UEsHCDjxwHEaAAAADgAAAFBLAQIeAxQACQAIAMAzIljmw5VkSgAAAAgHAAAMAAAAAAAAAAEAAACkgQAAAABkZWZsYXRlZC50eHRQSwECHgMKAAkAAADAMyJYOPHAcRoAAAAOAAAACgAAAAAAAAAAAAAApIGEAAAAc3RvcmVkLnR4dFBLBQYAAAAAAgACAHIAAADWAAAAAAA=
""".replacingOccurrences(of: "\n", with: ""))!
