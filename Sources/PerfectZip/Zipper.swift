import Foundation

/// One archive-creation run. `Zip` creates one per call.
struct Zipper {
    let paths: [String]
    let zipFilePath: String
    let overwrite: Bool

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
        let writer: ArchiveWriter
        do { writer = try ArchiveWriter(path: temporary) } catch { return .ZipFail }

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
            do {
                for item in items { try add(item, to: writer) }
                try writer.finish()
            } catch {
                status = .ZipFail
            }
        }
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

    private func add(_ item: Item, to writer: ArchiveWriter) throws {
        var st = stat()
        let name = Array(item.entryName.utf8)
        if item.isDirectory {
            guard stat(item.sourcePath, &st) == 0 else { throw ArchiveError.io("stat") }
            try writer.add(name: name, isDirectory: true, unixMode: UInt32(st.st_mode),
                           modified: Int(modificationTime(st)), sizeHint: 0, source: nil)
            return
        }
        let fd = open(item.sourcePath, O_RDONLY | O_CLOEXEC | (item.followLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { throw ArchiveError.io("open") }
        defer { closeFD(fd) }
        guard fstat(fd, &st) == 0, UInt32(st.st_mode) & FileType.mask == FileType.regular else {
            throw ArchiveError.io("not a regular file")
        }
        try writer.add(name: name, isDirectory: false, unixMode: UInt32(st.st_mode),
                       modified: Int(modificationTime(st)), sizeHint: UInt64(st.st_size)) { buffer, size in
            let n = readSome(fd, buffer, size)
            guard n >= 0 else { throw ArchiveError.io("read") }
            return n
        }
    }
}
