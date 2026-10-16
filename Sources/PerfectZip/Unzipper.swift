import Foundation
import minizip

/// One extraction run. Not shared between threads; `Zip` creates one per call.
struct Unzipper {
    let source: String
    let destination: String
    let overwrite: Bool
    let password: String

    private static let bufferSize = 64 * 1024
    /// "Version made by" host values whose external attributes carry a Unix `st_mode`.
    private static let unixHosts: Set<UInt> = [3 /* Unix */, 19 /* OS X */]

    private struct Entry {
        let path: EntryPath
        let info: unz_file_info64
    }

    func run() -> ZipStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { return .FileNotFound }
        if !overwrite && fm.fileExists(atPath: destination) { return .ZipCannotOverwrite }

        guard let zip = unzOpen64(source) else { return .UnzipFail }
        defer { unzClose(zip) }

        // Pass 1: read and check every entry name before anything is written, so a hostile
        // name anywhere in the archive fails the whole extraction with nothing extracted.
        var entries = [Entry]()
        switch readEntries(zip, into: &entries) {
        case .ZipSuccess: break
        case let failure: return failure
        }

        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        } catch {
            return .UnzipFail
        }
        // Entry paths are checked against the destination with its symlinks resolved, and all
        // writes happen relative to a descriptor for that resolved directory.
        guard let root = canonicalPath(destination) else { return .UnzipFail }
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return .UnzipFail }
        defer { closeFD(rootFD) }

        for entry in entries {
            switch entry.path {
            case .directory(let components), .file(let components):
                guard EntryPath.isContained(components, in: root) else { return .UnzipUnsafePath }
            case .skipped, .unsafe:
                break
            }
        }

        // Pass 2: extract, in archive order.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        guard unzGoToFirstFile(zip) == UNZ_OK else { return .UnzipFail }
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                guard unzGoToNextFile(zip) == UNZ_OK else { return .UnzipFail }
            }
            let status: ZipStatus
            switch entry.path {
            case .skipped:
                continue
            case .unsafe:
                return .UnzipUnsafePath // already rejected in pass 1
            case .directory(let components):
                let (fd, dirStatus) = openDirectory(components, under: rootFD)
                if fd >= 0 { closeFD(fd) }
                status = dirStatus
            case .file(let components):
                status = extractFile(zip, entry.info, components, under: rootFD, buffer: buffer)
            }
            guard status == .ZipSuccess else { return status }
        }
        return .ZipSuccess
    }

    /// Reads the central directory. Returns `.UnzipUnsafePath` for a hostile name and
    /// `.ZipCannotOverwrite` for a duplicate name when `overwrite` is false.
    private func readEntries(_ zip: unzFile, into entries: inout [Entry]) -> ZipStatus {
        var global = unz_global_info64()
        guard unzGetGlobalInfo64(zip, &global) == UNZ_OK else { return .UnzipFail }
        if global.number_entry == 0 { return .ZipSuccess }

        var seen = Set<[String]>()
        var ret = unzGoToFirstFile(zip)
        while ret == UNZ_OK {
            var info = unz_file_info64()
            guard unzGetCurrentFileInfo64(zip, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK else {
                return .UnzipFail
            }
            let nameLength = Int(info.size_filename)
            var name = [UInt8](repeating: 0, count: nameLength + 1)
            let got = name.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    unzGetCurrentFileInfo64(zip, &info, $0, UInt(nameLength), nil, 0, nil, 0)
                }
            }
            guard got == UNZ_OK else { return .UnzipFail }

            let path = EntryPath.validate(name.prefix(nameLength))
            switch path {
            case .unsafe:
                return .UnzipUnsafePath
            case .file(let components):
                if !seen.insert(components).inserted && !overwrite { return .ZipCannotOverwrite }
            case .directory, .skipped:
                break
            }
            entries.append(Entry(path: path, info: info))
            ret = unzGoToNextFile(zip)
        }
        // Anything other than a clean end of the central directory means it is damaged.
        return ret == UNZ_END_OF_LIST_OF_FILE ? .ZipSuccess : .UnzipFail
    }

    /// Opens (creating as needed) the directory `components` below `rootFD`, refusing to pass
    /// through a symbolic link at any level. Returns the descriptor, or -1 and a status.
    private func openDirectory(_ components: some Collection<String>, under rootFD: Int32) -> (Int32, ZipStatus) {
        var current = dup(rootFD)
        guard current >= 0 else { return (-1, .UnzipFail) }
        for component in components {
            if mkdirat(current, component, 0o755) != 0 && errno != EEXIST {
                closeFD(current)
                return (-1, .UnzipFail)
            }
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let isLink = fileType(at: current, component) == FileType.symlink
                closeFD(current)
                return (-1, isLink ? .UnzipUnsafePath : .UnzipFail)
            }
            closeFD(current)
            current = next
        }
        return (current, .ZipSuccess)
    }

    private func extractFile(_ zip: unzFile, _ info: unz_file_info64, _ components: [String],
                             under rootFD: Int32, buffer: UnsafeMutableRawPointer) -> ZipStatus {
        let isEncrypted = info.flag & 1 != 0
        if isEncrypted && password.isEmpty { return .UnzipFail }

        let (dirFD, dirStatus) = openDirectory(components.dropLast(), under: rootFD)
        guard dirFD >= 0 else { return dirStatus }
        defer { closeFD(dirFD) }
        let name = components[components.count - 1]

        var fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if fd < 0 {
            guard errno == EEXIST else { return .UnzipFail }
            guard overwrite else { return .ZipCannotOverwrite }
            switch fileType(at: dirFD, name) {
            case FileType.regular:
                fd = openat(dirFD, name, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return .UnzipFail }
            case FileType.symlink:
                // Never write through, or silently replace, a link inside the destination.
                return .UnzipUnsafePath
            default:
                return .UnzipFail
            }
        }

        let opened = isEncrypted
            ? unzOpenCurrentFilePassword(zip, password)
            : unzOpenCurrentFile(zip)
        guard opened == UNZ_OK else {
            closeFD(fd)
            _ = unlinkat(dirFD, name, 0)
            return .UnzipFail
        }

        var ok = true
        while true {
            let n = unzReadCurrentFile(zip, buffer, UInt32(Self.bufferSize))
            if n == 0 { break }
            if n < 0 || !writeAll(fd, buffer, Int(n)) { ok = false; break }
        }
        // unzCloseCurrentFile verifies the CRC once the whole entry has been read; a wrong
        // password usually shows up here (or as a read error above).
        if unzCloseCurrentFile(zip) != UNZ_OK { ok = false }

        if ok { applyAttributes(info, to: fd) }
        if close(fd) != 0 { ok = false }
        if !ok {
            _ = unlinkat(dirFD, name, 0)
            return .UnzipFail
        }
        return .ZipSuccess
    }

    /// Restores the permission bits (Unix-made archives only; never setuid, setgid or sticky)
    /// and the modification time.
    private func applyAttributes(_ info: unz_file_info64, to fd: Int32) {
        if Self.unixHosts.contains(info.version >> 8) {
            let mode = UInt32(truncatingIfNeeded: info.external_fa >> 16)
            let type = mode & FileType.mask
            let permissions = mode & 0o777
            if (type == FileType.regular || type == 0) && permissions != 0 {
                _ = fchmod(fd, mode_t(permissions))
            }
        }

        // DOS timestamps are local time with two-second resolution.
        var t = tm()
        t.tm_sec = Int32(info.tmu_date.tm_sec)
        t.tm_min = Int32(info.tmu_date.tm_min)
        t.tm_hour = Int32(info.tmu_date.tm_hour)
        t.tm_mday = Int32(info.tmu_date.tm_mday)
        t.tm_mon = Int32(info.tmu_date.tm_mon)
        t.tm_year = Int32(info.tmu_date.tm_year) - 1900
        t.tm_isdst = -1
        let seconds = mktime(&t)
        guard seconds != -1 else { return }
        var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
        _ = futimens(fd, &times)
    }
}
