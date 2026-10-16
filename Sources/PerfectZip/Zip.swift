import Foundation

/// Creates and extracts zip archives.
///
/// `Zip` holds only its immutable ``limits``, so one instance can be shared between threads;
/// each call works on its own files. Calls that write the same destination or archive
/// concurrently are not coordinated.
public final class Zip: Sendable {
    /// Zip-bomb limits applied by ``unzipFile(source:destination:overwrite:password:)``.
    public let limits: ZipLimits

    public init(limits: ZipLimits = .default) {
        self.limits = limits
    }

    /// Extracts the archive at `source` into the directory `destination`.
    ///
    /// - Parameters:
    ///   - overwrite: When `false`, extraction is refused with ``ZipStatus/ZipCannotOverwrite``
    ///     if `destination` already exists (or the archive names the same file twice). When
    ///     `true`, the destination may exist and existing regular files are replaced.
    ///   - password: The password for entries encrypted with traditional PKWARE encryption
    ///     ("ZipCrypto"). Empty means none. A missing or wrong password fails with
    ///     ``ZipStatus/UnzipIncorrectPassword`` before anything is written. AES-encrypted
    ///     entries are not supported (``ZipStatus/UnzipFail``).
    ///
    /// The whole archive is validated before anything is written: its structure (every length
    /// and offset, local headers against the central directory, no overlapping entries), the
    /// ``limits``, every entry name and the password. If any name is absolute, has a `..`
    /// component (with `/` or `\` separators), contains NUL, or would land outside
    /// `destination` (resolved through symlinks), nothing is extracted and the result is
    /// ``ZipStatus/UnzipUnsafePath``. While extracting, a symbolic link already inside the
    /// destination is never followed or replaced; meeting one also fails with
    /// ``ZipStatus/UnzipUnsafePath``. Symlink entries in the archive are extracted as regular
    /// files containing the link text, never as links. `__MACOSX/` metadata is skipped.
    ///
    /// On a failure during extraction, entries already written stay in `destination` (the
    /// failing file itself is removed). Nothing is ever written outside it.
    public func unzipFile(source: String, destination: String, overwrite: Bool, password: String = "") -> ZipStatus {
        Unzipper(source: source, destination: destination, overwrite: overwrite, password: password,
                 limits: limits).run()
    }

    /// Archives the files and directories at `paths` into a new zip file at `zipFilePath`.
    ///
    /// Each path becomes a top-level entry named after its last component; directories are
    /// added recursively, including empty ones. Symbolic links found while walking a directory
    /// are skipped; a path given directly in `paths` is followed if it is a link. `.DS_Store`
    /// files and `__MACOSX` directories are skipped. Two entries with the same name (for example
    /// `a/x.txt` and `b/x.txt` both given in `paths`) fail with ``ZipStatus/ZipFail``.
    /// Unix permissions and modification times are recorded; Zip64 is used where needed.
    ///
    /// The archive is written to a temporary file in the same directory and renamed into place,
    /// so on failure an existing `zipFilePath` is left untouched.
    ///
    /// - Parameters:
    ///   - zipFilePath: Must end in `.zip`.
    ///   - overwrite: When `false`, an existing `zipFilePath` fails with
    ///     ``ZipStatus/ZipCannotOverwrite``.
    public func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool) -> ZipStatus {
        Zipper(paths: paths, zipFilePath: zipFilePath, overwrite: overwrite).run()
    }

    /// 3.x signature. Writing encrypted archives is no longer supported: a non-empty `password`
    /// returns ``ZipStatus/ZipEncryptionUnsupported`` without creating anything. (3.x wrote a
    /// wrong check byte, so its encrypted archives could not be opened by other tools.)
    @available(*, deprecated, message: "Encrypted archives are no longer written; use zipFiles(paths:zipFilePath:overwrite:).")
    public func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool, password: String?) -> ZipStatus {
        if let password, !password.isEmpty { return .ZipEncryptionUnsupported }
        return zipFiles(paths: paths, zipFilePath: zipFilePath, overwrite: overwrite)
    }
}

/// Limits that stop zip bombs during ``Zip/unzipFile(source:destination:overwrite:password:)``.
///
/// Both are checked against the sizes the archive declares, before anything is written, and
/// extraction then refuses any entry that produces more bytes than it declared. Exceeding a
/// limit returns ``ZipStatus/UnzipLimitExceeded``.
public struct ZipLimits: Sendable, Hashable {
    /// The most bytes all entries together may expand to. Default 16 GiB.
    public var maxTotalUncompressedSize: UInt64
    /// The highest ratio of declared uncompressed size to compressed size (integer division)
    /// allowed for any entry of 1 MiB or more, and for the sum over all entries once that sum is
    /// 1 MiB or more. Default 200. Deflate cannot exceed about 1032:1, so a value above that
    /// disables the check.
    public var maxCompressionRatio: UInt64

    public init(maxTotalUncompressedSize: UInt64 = 16 << 30, maxCompressionRatio: UInt64 = 200) {
        self.maxTotalUncompressedSize = maxTotalUncompressedSize
        self.maxCompressionRatio = maxCompressionRatio
    }

    /// 16 GiB in total, ratio 200:1.
    public static let `default` = ZipLimits()
    /// No limits. Only for archives from a trusted source.
    public static let unlimited = ZipLimits(maxTotalUncompressedSize: .max, maxCompressionRatio: .max)
}
