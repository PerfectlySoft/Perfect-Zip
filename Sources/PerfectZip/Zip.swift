import Foundation

/// Creates and extracts zip archives.
///
/// `Zip` holds no state, so one instance can be shared between threads; each call works on its
/// own files. Calls that write the same destination or archive concurrently are not coordinated.
public final class Zip: Sendable {
    public init() {}

    /// Extracts the archive at `source` into the directory `destination`.
    ///
    /// - Parameters:
    ///   - overwrite: When `false`, extraction is refused with ``ZipStatus/ZipCannotOverwrite``
    ///     if `destination` already exists (or the archive names the same file twice). When
    ///     `true`, the destination may exist and existing regular files are replaced.
    ///   - password: The password for entries encrypted with traditional PKWARE encryption.
    ///     Empty means none; an encrypted entry then fails with ``ZipStatus/UnzipFail``.
    ///
    /// Every entry name is checked before anything is written. If any name is absolute, has a
    /// `..` component (with `/` or `\` separators), contains NUL, or would land outside
    /// `destination` (resolved through symlinks), nothing is extracted and the result is
    /// ``ZipStatus/UnzipUnsafePath``. While extracting, a symbolic link already inside the
    /// destination is never followed or replaced; meeting one also fails with
    /// ``ZipStatus/UnzipUnsafePath``. Symlink entries in the archive are extracted as regular
    /// files containing the link text, never as links. `__MACOSX/` metadata is skipped.
    ///
    /// On any failure after extraction starts, entries already written stay in `destination`
    /// (the failing file itself is removed). Nothing is ever written outside it.
    public func unzipFile(source: String, destination: String, overwrite: Bool, password: String = "") -> ZipStatus {
        Unzipper(source: source, destination: destination, overwrite: overwrite, password: password).run()
    }

    /// Archives the files and directories at `paths` into a new zip file at `zipFilePath`.
    ///
    /// Each path becomes a top-level entry named after its last component; directories are
    /// added recursively, including empty ones. Symbolic links found while walking a directory
    /// are skipped; a path given directly in `paths` is followed if it is a link. `.DS_Store`
    /// files and `__MACOSX` directories are skipped. Two entries with the same name (for example
    /// `a/x.txt` and `b/x.txt` both given in `paths`) fail with ``ZipStatus/ZipFail``.
    ///
    /// The archive is written to a temporary file in the same directory and renamed into place,
    /// so on failure an existing `zipFilePath` is left untouched.
    ///
    /// - Parameters:
    ///   - zipFilePath: Must end in `.zip`.
    ///   - overwrite: When `false`, an existing `zipFilePath` fails with
    ///     ``ZipStatus/ZipCannotOverwrite``.
    ///   - password: `nil` or empty for no encryption. Otherwise entries use traditional PKWARE
    ///     encryption, which is weak and only suitable for compatibility, not secrecy.
    public func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool, password: String?) -> ZipStatus {
        Zipper(paths: paths, zipFilePath: zipFilePath, overwrite: overwrite, password: password).run()
    }
}
