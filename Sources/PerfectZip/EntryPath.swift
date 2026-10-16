import Foundation

/// What an archive entry name means once it has been checked.
enum EntryPath: Equatable, Sendable {
    /// The most path components an entry may have. Deeper names are refused as unsafe: real
    /// archives come nowhere near this, and deep nesting is a resource-exhaustion trick.
    static let maxDepth = 256

    /// A directory, as path components relative to the destination.
    case directory([String])
    /// A regular file, as path components relative to the destination.
    case file([String])
    /// macOS Finder metadata (`__MACOSX/...`), which is not extracted.
    case skipped
    /// The name is absolute, empty, contains NUL or a `..` component, or otherwise cannot be
    /// placed inside the destination. Extraction stops with ``ZipStatus/UnzipUnsafePath``.
    case unsafe

    /// Checks raw name bytes, decoded as ``NameEncoding`` does without the UTF-8 flag.
    static func validate(_ raw: some Collection<UInt8>) -> EntryPath {
        NameEncoding.decode(Array(raw), utf8Flag: false).map(validate) ?? .unsafe
    }

    /// Checks a decoded entry name from the archive's central directory.
    ///
    /// Backslashes are treated as path separators (archives made on Windows use them), so
    /// `..\x` is caught the same way as `../x`. Empty and `.` components are dropped.
    static func validate(_ decoded: String) -> EntryPath {
        guard !decoded.isEmpty, !decoded.unicodeScalars.contains("\0") else { return .unsafe }
        let name = decoded.replacingOccurrences(of: "\\", with: "/")
        // Absolute POSIX paths, and Windows drive paths such as `C:/x` or `C:x`.
        if name.hasPrefix("/") { return .unsafe }
        let scalars = Array(name.unicodeScalars.prefix(2))
        if scalars.count == 2, scalars[1] == ":", scalars[0].isASCII,
           scalars[0].properties.isAlphabetic {
            return .unsafe
        }

        let isDirectory = name.hasSuffix("/")
        var components = [String]()
        for part in name.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": return .unsafe
            default: components.append(String(part))
            }
        }
        guard !components.isEmpty, components.count <= maxDepth else { return .unsafe }
        if components.contains("__MACOSX") { return .skipped }
        return isDirectory ? .directory(components) : .file(components)
    }

    /// Belt and braces for the lexical check: joins `components` onto the canonical
    /// destination `root`, normalizes `.` and `..` purely lexically, and confirms the result is
    /// still strictly below `root`. (Foundation's standardizing is not used: on Darwin it
    /// rewrites `/private/var/...` to `/var/...` for paths that exist, which breaks the
    /// comparison with a `realpath` result.)
    static func isContained(_ components: [String], in root: String) -> Bool {
        let base = root.split(separator: "/").map(String.init)
        var resolved = base
        for part in components.flatMap({ $0.split(separator: "/").map(String.init) }) {
            switch part {
            case "", ".": continue
            case "..":
                guard !resolved.isEmpty else { return false }
                resolved.removeLast()
            default: resolved.append(part)
            }
        }
        return resolved.count > base.count && Array(resolved.prefix(base.count)) == base
    }
}
