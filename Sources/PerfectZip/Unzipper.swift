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
            var seen = Set<[String]>()
            for info in try reader.entries(limits: limits) {
                let path = info.name.map(EntryPath.validate) ?? .unsafe
                switch path {
                case .unsafe:
                    return .UnzipUnsafePath
                case .file(let components):
                    if !seen.insert(components).inserted && !overwrite { return .ZipCannotOverwrite }
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
                status = extractFile(reader, entry.info, components, under: rootFD,
                                     password: passwordBytes, input: input, output: output)
            }
            guard status == .ZipSuccess else { return status }
        }
        return .ZipSuccess
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

    private func extractFile(_ reader: ArchiveReader, _ info: ArchiveEntry, _ components: [String],
                             under rootFD: Int32, password: [UInt8],
                             input: UnsafeMutableRawPointer, output: UnsafeMutableRawPointer) -> ZipStatus {
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

        var status = ZipStatus.ZipSuccess
        do {
            try reader.extract(info, password: password, input: input, output: output) { base, count in
                guard writeAll(fd, base, count) else { throw ArchiveError.io("write") }
            }
            applyAttributes(info, to: fd)
        } catch let error as ArchiveError {
            status = error.status
        } catch {
            status = .UnzipFail
        }
        if close(fd) != 0 && status == .ZipSuccess { status = .UnzipFail }
        if status != .ZipSuccess { _ = unlinkat(dirFD, name, 0) }
        return status
    }

    /// Restores the permission bits (Unix-made archives only; never setuid, setgid or sticky)
    /// and the modification time (the UTC "UT" extra field if present, else the DOS time).
    private func applyAttributes(_ info: ArchiveEntry, to fd: Int32) {
        if let mode = info.unixMode {
            let type = mode & FileType.mask
            let permissions = mode & 0o777
            if (type == FileType.regular || type == 0) && permissions != 0 {
                _ = fchmod(fd, mode_t(permissions))
            }
        }
        guard let seconds = info.modificationTime else { return }
        var times = [timespec(tv_sec: time_t(seconds), tv_nsec: 0), timespec(tv_sec: time_t(seconds), tv_nsec: 0)]
        _ = futimens(fd, &times)
    }
}
