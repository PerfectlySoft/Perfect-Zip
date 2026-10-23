import Foundation

// Small wrappers over the POSIX calls the zipper and unzipper use directly. Extraction works
// relative to directory file descriptors (openat/mkdirat with O_NOFOLLOW) so that a symbolic
// link inside the destination can never redirect a write, which path strings cannot guarantee.

enum FileType {
    static let mask: UInt32 = 0o170000
    static let regular: UInt32 = 0o100000
    static let directory: UInt32 = 0o040000
    static let symlink: UInt32 = 0o120000
}

/// The `st_mode` file-type bits of `name` in `dirfd`, without following a final symlink.
func fileType(at dirfd: Int32, _ name: String) -> UInt32? {
    var st = stat()
    guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
    return UInt32(st.st_mode) & FileType.mask
}

/// Writes all of `count` bytes, retrying short writes and EINTR.
func writeAll(_ fd: Int32, _ base: UnsafeRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = write(fd, base + offset, count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        offset += n
    }
    return true
}

/// Reads up to `count` bytes, retrying EINTR. Returns -1 on error, 0 at end of file.
func readSome(_ fd: Int32, _ base: UnsafeMutableRawPointer, _ count: Int) -> Int {
    while true {
        let n = read(fd, base, count)
        if n < 0 && errno == EINTR { continue }
        return n
    }
}

/// Closes `fd`, ignoring EINTR (the descriptor is released either way on Darwin and Linux).
func closeFD(_ fd: Int32) {
    _ = close(fd)
}

/// `realpath(3)`: the absolute, symlink-free path of an existing file.
func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The modification time of a `stat` result, in seconds since the epoch.
func modificationTime(_ st: stat) -> time_t {
    #if canImport(Darwin)
    return st.st_mtimespec.tv_sec
    #else
    return st.st_mtim.tv_sec
    #endif
}
