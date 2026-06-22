import Foundation

public enum ZipStatus: Error, Sendable {
    case FileNotFound
    case UnzipFail
    case ZipFail
    case ZipCannotOverwrite
    case ZipSuccess

    public var description: String {
        switch self {
        case .FileNotFound:       return "File not found."
        case .UnzipFail:          return "Failed to unzip file."
        case .ZipFail:            return "Failed to zip file."
        case .ZipCannotOverwrite: return "Cannot overwrite destination file."
        case .ZipSuccess:         return "Success."
        }
    }
}

public struct ProcessedFilePath: Sendable {
    let filePath: String
    let fileDir: String
    let fileName: String?
}

struct ZipUtilities {
    func processZipPaths(_ path: String, parentDir: String) -> [ProcessedFilePath] {
        var result = [ProcessedFilePath]()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return result }

        if !isDir.boolValue {
            guard lastPathComponent(path) != ".DS_Store" else { return result }
            let clean = path.replacingOccurrences(of: "//", with: "/")
            result.append(ProcessedFilePath(filePath: clean, fileDir: parentDir, fileName: lastPathComponent(clean)))
        } else if !path.contains("__MACOSX") {
            let thisNewParent = lastPathComponent(path)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return result }
            for n in entries {
                let newpath = (path + "/" + n).replacingOccurrences(of: "//", with: "/")
                let newParent = parentDir.isEmpty ? thisNewParent : parentDir + "/" + thisNewParent
                result += processZipPaths(newpath, parentDir: newParent)
            }
        }
        return result
    }

    func lastPathComponent(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? ""
    }
}
