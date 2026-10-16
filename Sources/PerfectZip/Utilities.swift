/// The result of a ``Zip`` operation. `ZipSuccess` is the only success value.
public enum ZipStatus: Error, Sendable, CustomStringConvertible {
    case FileNotFound
    case UnzipFail
    case ZipFail
    case ZipCannotOverwrite
    case ZipSuccess
    /// An archive entry's name is absolute, contains `..` or NUL, would land outside the
    /// destination, or the extraction would have to go through a symbolic link. New in 4.0.
    case UnzipUnsafePath

    public var description: String {
        switch self {
        case .FileNotFound:       return "File not found."
        case .UnzipFail:          return "Failed to unzip file."
        case .ZipFail:            return "Failed to zip file."
        case .ZipCannotOverwrite: return "Cannot overwrite destination file."
        case .ZipSuccess:         return "Success."
        case .UnzipUnsafePath:    return "Archive entry path is unsafe (absolute, contains '..', or leads outside the destination or through a symbolic link); refusing to extract."
        }
    }
}

/// Unused since 4.0; kept only so code that names the type still compiles.
@available(*, deprecated, message: "Not used by PerfectZip; it has no public members.")
public struct ProcessedFilePath: Sendable {
    let filePath: String
    let fileDir: String
    let fileName: String?
}
