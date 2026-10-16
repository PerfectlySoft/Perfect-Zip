import Foundation
import minizip

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

    func read(_ name: String) -> String? {
        FileManager.default.contents(atPath: sub(name)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every path below the scratch directory, relative to it.
    func allPaths() -> Set<String> {
        Set((try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? [])
    }
}

/// An entry for ``makeArchive(at:_:)``, written with minizip's own zip API so names can be
/// anything an attacker could put in an archive.
struct RawEntry {
    var name: String
    var contents: String = ""
    /// Unix `st_mode` to store in the external attributes (with a Unix "version made by").
    var unixMode: UInt32? = nil
}

enum ArchiveError: Error { case failed(String) }

func makeArchive(at path: String, _ entries: [RawEntry]) throws {
    guard let zip = zipOpen64(path, APPEND_STATUS_CREATE) else { throw ArchiveError.failed("open") }
    for entry in entries {
        var info = zip_fileinfo(tmz_date: tm_zip(tm_sec: 0, tm_min: 0, tm_hour: 12, tm_mday: 1, tm_mon: 0, tm_year: 2024),
                                dosDate: 0, internal_fa: 0,
                                external_fa: entry.unixMode.map { UInt($0) << 16 } ?? 0)
        let madeBy: UInt = entry.unixMode == nil ? 0 : 0x031E
        guard zipOpenNewFileInZip4_64(zip, entry.name, &info, nil, 0, nil, 0, nil,
                                      Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0, -MAX_WBITS, DEF_MEM_LEVEL,
                                      Z_DEFAULT_STRATEGY, nil, 0, madeBy, 0, 0) == ZIP_OK else {
            throw ArchiveError.failed("entry \(entry.name)")
        }
        let bytes = Array(entry.contents.utf8)
        if !bytes.isEmpty {
            guard zipWriteInFileInZip(zip, bytes, UInt32(bytes.count)) == ZIP_OK else {
                throw ArchiveError.failed("write")
            }
        }
        guard zipCloseFileInZip(zip) == ZIP_OK else { throw ArchiveError.failed("close entry") }
    }
    guard zipClose(zip, nil) == ZIP_OK else { throw ArchiveError.failed("close") }
}

/// The entry names in an archive, in order, read with minizip's unzip API.
func entryNames(of path: String) throws -> [String] {
    guard let zip = unzOpen64(path) else { throw ArchiveError.failed("unzOpen") }
    defer { unzClose(zip) }
    var names = [String]()
    var ret = unzGoToFirstFile(zip)
    while ret == UNZ_OK {
        var info = unz_file_info64()
        var buf = [CChar](repeating: 0, count: 65537)
        guard unzGetCurrentFileInfo64(zip, &info, &buf, UInt(buf.count - 1), nil, 0, nil, 0) == UNZ_OK else {
            throw ArchiveError.failed("info")
        }
        names.append(String(decoding: buf.prefix(Int(info.size_filename)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        ret = unzGoToNextFile(zip)
    }
    guard ret == UNZ_END_OF_LIST_OF_FILE else { throw ArchiveError.failed("walk") }
    return names
}

/// Replaces every occurrence of `find` with `replace` (same length) in the file's bytes; used to
/// plant names minizip's C-string API cannot express, such as an embedded NUL.
func patchBytes(_ path: String, find: [UInt8], replace: [UInt8]) throws {
    precondition(find.count == replace.count)
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    var i = 0
    var hits = 0
    while i + find.count <= data.count {
        if Array(data[i..<i + find.count]) == find {
            data.replaceSubrange(i..<i + find.count, with: replace)
            hits += 1
            i += find.count
        } else {
            i += 1
        }
    }
    guard hits > 0 else { throw ArchiveError.failed("pattern not found") }
    try Data(data).write(to: URL(fileURLWithPath: path))
}
