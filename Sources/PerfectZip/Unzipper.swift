import Foundation

/// One extraction run. Not shared between threads; `Zip` creates one per call.
struct Unzipper {
    let source: String
    let destination: String
    let overwrite: Bool
    let password: String
    let limits: ZipLimits

    private struct Entry {
        let path: EntryPath
        let info: ArchiveEntry
    }

    func run() -> ZipStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { return .FileNotFound }
        if !overwrite && fm.fileExists(atPath: destination) { return .ZipCannotOverwrite }

        // Pass 1: parse and validate the whole archive (structure, limits, every name, the
        // password) before anything is written, so a hostile or damaged archive fails with
        // nothing extracted.
        let reader: ArchiveReader
        var entries = [Entry]()
        let passwordBytes = Array(password.utf8)
        do {
            reader = try ArchiveReader(path: source)
            // Compared as bytes, as the filesystem does: Swift's String equality would treat
            // NFC and NFD spellings as the same name, which they are not on Linux. (Names that a
            // filesystem folds together, such as case on APFS, meet at create time instead and
            // fail closed there.)
            var seen = Set<[UInt8]>()
            for info in try reader.entries(limits: limits) {
                let path = info.name.map(EntryPath.validate) ?? .unsafe
                switch path {
                case .unsafe:
                    return .UnzipUnsafePath
                case .file(let components):
                    let key = Array(components.joined(separator: "/").utf8)
                    if !seen.insert(key).inserted && !overwrite { return .ZipCannotOverwrite }
                    if info.isEncrypted {
                        guard !passwordBytes.isEmpty else { return .UnzipIncorrectPassword }
                        try reader.checkPassword(info, passwordBytes)
                    }
                case .directory, .skipped:
                    break
                }
                entries.append(Entry(path: path, info: info))
            }
        } catch let error as ArchiveError {
            return error.status
        } catch {
            return .UnzipFail
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
        guard let umask = currentUmask(in: rootFD) else { return .UnzipFail }

        for entry in entries {
            switch entry.path {
            case .directory(let components), .file(let components):
                guard EntryPath.isContained(components, in: root) else { return .UnzipUnsafePath }
            case .skipped, .unsafe:
                break
            }
        }

        // Pass 2: extract, in archive order, through two fixed buffers.
        let input = UnsafeMutableRawPointer.allocate(byteCount: ArchiveReader.bufferSize, alignment: 16)
        let output = UnsafeMutableRawPointer.allocate(byteCount: ArchiveReader.bufferSize, alignment: 16)
        defer { input.deallocate(); output.deallocate() }

        for entry in entries {
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
                status = extractFile(reader, entry.info, components, under: rootFD, umask: umask,
                                     password: passwordBytes, input: input, output: output)
            }
            guard status == .ZipSuccess else { return status }
        }
        return .ZipSuccess
    }

    /// Opens (creating as needed) the directory `components` below `rootFD`, refusing to pass
    /// through a symbolic link at any level. Returns the descriptor, or -1 and a status.
    ///
    /// Every entry walks from the destination root again, on purpose: a descriptor kept from
    /// an earlier entry would keep writing into its directory even after that directory had
    /// been moved out of the destination. ``EntryPath/maxDepth`` bounds the cost of the walk.
    private func openDirectory(_ components: some Collection<String>, under rootFD: Int32) -> (Int32, ZipStatus) {
        var current = dup(rootFD)
        guard current >= 0 else { return (-1, .UnzipFail) }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        for component in components {
            // Open first and create only when missing: one system call per existing level.
            var next = openat(current, component, flags)
            if next < 0 && errno == ENOENT {
                if mkdirat(current, component, 0o755) != 0 && errno != EEXIST {
                    closeFD(current)
                    return (-1, .UnzipFail)
                }
                next = openat(current, component, flags)
            }
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

    private func extractFile(_ reader: ArchiveReader, _ info: ArchiveEntry, _ components: [String],
                             under rootFD: Int32, umask: mode_t, password: [UInt8],
                             input: UnsafeMutableRawPointer, output: UnsafeMutableRawPointer) -> ZipStatus {
        let (dirFD, dirStatus) = openDirectory(components.dropLast(), under: rootFD)
        guard dirFD >= 0 else { return dirStatus }
        defer { closeFD(dirFD) }
        let name = components[components.count - 1]

        // A new file is created under its own name. An existing one is never truncated or
        // written in place: the entry goes to a temporary file in the same directory, which is
        // renamed over the original only once it is complete and its CRC has checked out. So
        // a failure keeps the original, and a hard link to the original (perhaps from outside
        // the destination) is broken rather than written through.
        var fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        var temporary: String?
        var replacedMode: mode_t?
        if fd < 0 {
            guard errno == EEXIST else { return .UnzipFail }
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return .UnzipFail }
            switch UInt32(st.st_mode) & FileType.mask {
            case FileType.symlink:
                // Never write through, or replace, a link inside the destination.
                return .UnzipUnsafePath
            case FileType.regular:
                guard overwrite else { return .ZipCannotOverwrite }
                replacedMode = st.st_mode & 0o777
                for _ in 0..<8 where fd < 0 {
                    let candidate = ".perfectzip-\(UInt64.random(in: 0...UInt64.max)).tmp"
                    fd = openat(dirFD, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if fd >= 0 { temporary = candidate } else if errno != EEXIST { break }
                }
                guard fd >= 0 else { return .UnzipFail }
            default:
                // A directory (or anything else) where the archive has a file.
                return overwrite ? .UnzipFail : .ZipCannotOverwrite
            }
        }
        let written = temporary ?? name

        var status = ZipStatus.ZipSuccess
        do {
            try reader.extract(info, password: password, input: input, output: output) { base, count in
                guard writeAll(fd, base, count) else { throw ArchiveError.io("write") }
            }
            applyAttributes(info, to: fd, umask: umask, replacing: replacedMode)
        } catch let error as ArchiveError {
            status = error.status
        } catch {
            status = .UnzipFail
        }
        if close(fd) != 0 && status == .ZipSuccess { status = .UnzipFail }
        if status == .ZipSuccess, let temporary, renameat(dirFD, temporary, dirFD, name) != 0 {
            status = .UnzipFail // for example, the target became a directory meanwhile
        }
        if status != .ZipSuccess { _ = unlinkat(dirFD, written, 0) }
        return status
    }

    /// The process umask, read without changing it: `umask(2)` can only be read by setting it,
    /// which races with other threads creating files. Instead a probe file is created with mode
    /// 0o777 in the destination (where `open` applies the umask atomically) and removed again.
    /// (A default ACL on the destination directory, where supported, takes the umask's place,
    /// and that is what the probe then reports.)
    private func currentUmask(in rootFD: Int32) -> mode_t? {
        for _ in 0..<8 {
            let name = ".perfectzip-\(UInt64.random(in: 0...UInt64.max)).umask"
            let fd = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o777)
            if fd < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            var st = stat()
            let ok = fstat(fd, &st) == 0
            closeFD(fd)
            _ = unlinkat(rootFD, name, 0)
            return ok ? ~st.st_mode & 0o777 : nil
        }
        return nil
    }

    /// Restores the permission bits and the modification time (the UTC "UT" extra field if
    /// present, else the DOS time). Permissions come from the archive for Unix-made entries
    /// (less the umask);
    /// otherwise a replaced file keeps its old permissions. Setuid, setgid and sticky bits are
    /// never set.
    private func applyAttributes(_ info: ArchiveEntry, to fd: Int32, umask: mode_t, replacing oldMode: mode_t?) {
        var permissions: mode_t?
        if let mode = info.unixMode {
            let type = mode & FileType.mask
            if (type == FileType.regular || type == 0) && mode & 0o777 != 0 {
                // The process umask applies, as with bsdtar, so an archive cannot create
                // world-writable files where the process wouldn't.
                permissions = mode_t(mode & 0o777) & ~umask
            }
        }
        // A new file without a Unix mode keeps the 0o644 (less umask) it was created with.
        if let permissions = permissions ?? oldMode { _ = fchmod(fd, permissions) }
        guard let seconds = info.modificationTime else { return }
        var times = [timespec(tv_sec: time_t(seconds), tv_nsec: 0), timespec(tv_sec: time_t(seconds), tv_nsec: 0)]
        _ = futimens(fd, &times)
    }
}
