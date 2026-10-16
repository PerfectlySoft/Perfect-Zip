import Foundation
import minizip

/// One archive-creation run. `Zip` creates one per call.
struct Zipper {
    let paths: [String]
    let zipFilePath: String
    let overwrite: Bool
    let password: String?

    private static let bufferSize = 64 * 1024
    /// Unix host (3), spec version 3.0, as Info-ZIP writes it, so readers honour the mode bits.
    private static let versionMadeBy: UInt = 0x031E
    /// Above this size an entry is written with Zip64 fields. Leaves room for deflate overhead
    /// and the encryption header on incompressible data just under 4 GiB.
    private static let zip64Threshold: UInt64 = 0xFF00_0000

    /// minizip's encryption header uses `rand()` and a function-level static, which are not
    /// thread-safe; serialize opening encrypted entries so concurrent `zipFiles` calls are safe.
    private static let cryptLock = NSLock()

    struct Item {
        let sourcePath: String
        let entryName: String
        let isDirectory: Bool
        /// Whether a symlink at `sourcePath` may be followed (only for paths the caller named).
        let followLinks: Bool
    }

    func run() -> ZipStatus {
        let fm = FileManager.default
        guard zipFilePath.hasSuffix(".zip") else { return .ZipFail }
        if !overwrite && fm.fileExists(atPath: zipFilePath) { return .ZipCannotOverwrite }
        for path in paths {
            guard fm.fileExists(atPath: path) else { return .FileNotFound }
        }

        // Build into a temporary file next to the target and rename it into place at the end,
        // so a failure never leaves a truncated archive or destroys the one being replaced.
        let target = URL(fileURLWithPath: zipFilePath)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp").path
        guard let zip = zipOpen64(temporary, APPEND_STATUS_CREATE) else { return .ZipFail }

        // Never put the archive being written, or the one it replaces, inside itself.
        var skip = [(dev_t, ino_t)]()
        for path in [temporary, zipFilePath] {
            var st = stat()
            if stat(path, &st) == 0 { skip.append((st.st_dev, st.st_ino)) }
        }
        var items = [Item]()
        var names = Set<String>()
        var status = ZipStatus.ZipSuccess
        for path in paths {
            status = collect(path, followLinks: true, parent: nil, into: &items, names: &names,
                             skipping: skip)
            if status != .ZipSuccess { break }
        }

        if status == .ZipSuccess {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            for item in items {
                status = add(item, to: zip, buffer: buffer)
                if status != .ZipSuccess { break }
            }
        }

        if zipClose(zip, nil) != ZIP_OK && status == .ZipSuccess { status = .ZipFail }
        guard status == .ZipSuccess, rename(temporary, zipFilePath) == 0 else {
            _ = unlink(temporary)
            return status == .ZipSuccess ? .ZipFail : status
        }
        return .ZipSuccess
    }

    /// Lists the entries for `path`. Directories are walked recursively; symbolic links found
    /// while walking are skipped (not followed), so a link cannot pull in files from outside
    /// the tree or loop forever. A path the caller named explicitly is followed if it is a link.
    private func collect(_ path: String, followLinks: Bool, parent: String?, into items: inout [Item],
                         names: inout Set<String>, skipping skip: [(dev_t, ino_t)]) -> ZipStatus {
        var st = stat()
        let found = followLinks ? stat(path, &st) : lstat(path, &st)
        guard found == 0 else { return parent == nil ? .FileNotFound : .ZipFail }
        if skip.contains(where: { $0.0 == st.st_dev && $0.1 == st.st_ino }) { return .ZipSuccess }

        // Entry names never contain `..`, `.` or a leading `/`: top-level names come from the
        // standardized path, and directory listings never return those components.
        let base: String
        if parent == nil {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            base = standardized.path == "/" ? "" : standardized.lastPathComponent
        } else {
            base = URL(fileURLWithPath: path).lastPathComponent
        }
        let name = [parent, base].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")

        switch UInt32(st.st_mode) & FileType.mask {
        case FileType.regular:
            guard base != ".DS_Store", !name.isEmpty else { return .ZipSuccess }
            guard names.insert(name).inserted else { return .ZipFail } // duplicate entry name
            items.append(Item(sourcePath: path, entryName: name, isDirectory: false, followLinks: followLinks))
            return .ZipSuccess
        case FileType.directory:
            guard base != "__MACOSX" else { return .ZipSuccess }
            if !name.isEmpty {
                guard names.insert(name + "/").inserted else { return .ZipFail }
                items.append(Item(sourcePath: path, entryName: name + "/", isDirectory: true, followLinks: followLinks))
            }
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return .ZipFail
            }
            let directory = path.hasSuffix("/") ? path : path + "/"
            for child in children.sorted() {
                let status = collect(directory + child, followLinks: false, parent: name,
                                     into: &items, names: &names, skipping: skip)
                if status != .ZipSuccess { return status }
            }
            return .ZipSuccess
        default:
            // Symlinks met while walking, sockets, FIFOs and devices are not archived.
            return .ZipSuccess
        }
    }

    private func add(_ item: Item, to zip: zipFile, buffer: UnsafeMutableRawPointer) -> ZipStatus {
        var fd: Int32 = -1
        var st = stat()
        if item.isDirectory {
            guard stat(item.sourcePath, &st) == 0 else { return .ZipFail }
        } else {
            let flags = O_RDONLY | O_CLOEXEC | (item.followLinks ? 0 : O_NOFOLLOW)
            fd = open(item.sourcePath, flags)
            guard fd >= 0 else { return .ZipFail }
            guard fstat(fd, &st) == 0, UInt32(st.st_mode) & FileType.mask == FileType.regular else {
                closeFD(fd)
                return .ZipFail
            }
        }
        defer { if fd >= 0 { closeFD(fd) } }

        let mode = UInt32(st.st_mode)
        var info = zip_fileinfo(tmz_date: Self.zipDate(modificationTime(st)), dosDate: 0, internal_fa: 0,
                                external_fa: UInt(mode) << 16 | (item.isDirectory ? 0x10 : 0))
        let size = UInt64(st.st_size)
        let usePassword = !item.isDirectory && !(password ?? "").isEmpty

        // Traditional PKWARE encryption stores the high bytes of the entry's CRC in the
        // encryption header, and other unzip tools check it, so compute the CRC first.
        var crcForCrypting: UInt = 0
        if usePassword {
            var crc = crc32(0, nil, 0)
            while true {
                let n = readSome(fd, buffer, Self.bufferSize)
                if n < 0 { return .ZipFail }
                if n == 0 { break }
                crc = crc32(crc, buffer.assumingMemoryBound(to: UInt8.self), UInt32(n))
            }
            guard lseek(fd, 0, SEEK_SET) == 0 else { return .ZipFail }
            crcForCrypting = UInt(crc)
        }

        let method = item.isDirectory ? 0 : Z_DEFLATED
        let level = item.isDirectory ? 0 : Z_DEFAULT_COMPRESSION
        let zip64: Int32 = size >= Self.zip64Threshold ? 1 : 0
        let opened: Int32
        if usePassword {
            Self.cryptLock.lock()
            opened = zipOpenNewFileInZip4_64(zip, item.entryName, &info, nil, 0, nil, 0, nil,
                                             method, level, 0, -MAX_WBITS, DEF_MEM_LEVEL,
                                             Z_DEFAULT_STRATEGY, password, crcForCrypting,
                                             Self.versionMadeBy, 0, zip64)
            Self.cryptLock.unlock()
        } else {
            opened = zipOpenNewFileInZip4_64(zip, item.entryName, &info, nil, 0, nil, 0, nil,
                                             method, level, 0, -MAX_WBITS, DEF_MEM_LEVEL,
                                             Z_DEFAULT_STRATEGY, nil, 0,
                                             Self.versionMadeBy, 0, zip64)
        }
        guard opened == ZIP_OK else { return .ZipFail }

        var ok = true
        if !item.isDirectory {
            while true {
                let n = readSome(fd, buffer, Self.bufferSize)
                if n == 0 { break }
                if n < 0 || zipWriteInFileInZip(zip, buffer, UInt32(n)) != ZIP_OK { ok = false; break }
            }
        }
        if zipCloseFileInZip(zip) != ZIP_OK { ok = false }
        return ok ? .ZipSuccess : .ZipFail
    }

    /// Local broken-down time for the DOS date field, clamped to its 1980...2107 range.
    private static func zipDate(_ seconds: time_t) -> tm_zip {
        var clock = seconds
        var t = tm()
        guard localtime_r(&clock, &t) != nil else {
            return tm_zip(tm_sec: 0, tm_min: 0, tm_hour: 0, tm_mday: 1, tm_mon: 0, tm_year: 1980)
        }
        let year = Int(t.tm_year) + 1900
        if year < 1980 {
            return tm_zip(tm_sec: 0, tm_min: 0, tm_hour: 0, tm_mday: 1, tm_mon: 0, tm_year: 1980)
        }
        if year > 2107 {
            return tm_zip(tm_sec: 58, tm_min: 59, tm_hour: 23, tm_mday: 31, tm_mon: 11, tm_year: 2107)
        }
        return tm_zip(tm_sec: .init(t.tm_sec), tm_min: .init(t.tm_min), tm_hour: .init(t.tm_hour),
                      tm_mday: .init(t.tm_mday), tm_mon: .init(t.tm_mon), tm_year: .init(year))
    }
}
