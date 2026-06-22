import Foundation
import minizip

public final class Zip: Sendable {
    public init() {}

    /// Unzip a file from `source` into the `destination` directory.
    public func unzipFile(source: String, destination: String, overwrite: Bool, password: String = "") -> ZipStatus {
        let fm = FileManager.default

        guard fm.fileExists(atPath: source) else { return .FileNotFound }

        if !overwrite && fm.fileExists(atPath: destination) {
            return .ZipCannotOverwrite
        }

        let destPath = destination.hasSuffix("/") ? destination : destination + "/"
        let bufferSize: UInt32 = 4096
        var buffer = [UInt8](repeating: 0, count: Int(bufferSize))

        guard let zip = unzOpen64(source) else { return .UnzipFail }
        defer { unzClose(zip) }

        guard unzGoToFirstFile(zip) == UNZ_OK else { return .UnzipFail }

        var ret: Int32 = UNZ_OK
        repeat {
            guard unzOpenCurrentFile(zip) == UNZ_OK else { return .UnzipFail }

            var fileInfo = unz_file_info64()
            guard unzGetCurrentFileInfo64(zip, &fileInfo, nil, 0, nil, 0, nil, 0) == UNZ_OK else {
                unzCloseCurrentFile(zip)
                return .UnzipFail
            }

            let nameLen = Int(fileInfo.size_filename)
            let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: nameLen + 1)
            defer { nameBuf.deallocate() }
            unzGetCurrentFileInfo64(zip, &fileInfo, nameBuf, UInt(nameLen + 1), nil, 0, nil, 0)
            nameBuf[nameLen] = 0

            var pathString = String(cString: nameBuf)
            let isDirectory = nameLen > 0 && nameBuf[nameLen - 1] == 47 // '/'

            if pathString.contains("\\") {
                pathString = pathString
                    .replacingOccurrences(of: "\\", with: "/")
                    .replacingOccurrences(of: "//", with: "/")
            }
            let fullPath = destPath + pathString

            if isDirectory {
                if !fullPath.contains("__MACOSX") {
                    try? fm.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
                }
            } else {
                let parentPath = URL(fileURLWithPath: fullPath).deletingLastPathComponent().path
                try? fm.createDirectory(atPath: parentPath, withIntermediateDirectories: true)

                if !fm.fileExists(atPath: fullPath) || overwrite {
                    fm.createFile(atPath: fullPath, contents: nil)
                    if let writeHandle = FileHandle(forWritingAtPath: fullPath) {
                        defer { writeHandle.closeFile() }
                        var readBytes: Int32 = 0
                        repeat {
                            readBytes = buffer.withUnsafeMutableBytes { ptr in
                                unzReadCurrentFile(zip, ptr.baseAddress!, bufferSize)
                            }
                            if readBytes > 0 {
                                writeHandle.write(Data(buffer.prefix(Int(readBytes))))
                            }
                        } while readBytes > 0
                    }
                }
            }

            let crcRet = unzCloseCurrentFile(zip)
            if crcRet == UNZ_CRCERROR { return .UnzipFail }
            ret = unzGoToNextFile(zip)

        } while ret == UNZ_OK

        return .ZipSuccess
    }

    /// Zip the files/directories at `paths` into a single archive at `zipFilePath`.
    public func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool, password: String?) -> ZipStatus {
        let fm = FileManager.default

        guard zipFilePath.hasSuffix(".zip") else { return .ZipFail }

        if !overwrite && fm.fileExists(atPath: zipFilePath) { return .ZipCannotOverwrite }

        for path in paths {
            guard fm.fileExists(atPath: path) else { return .FileNotFound }
        }

        let utils = ZipUtilities()
        var processedPaths = [ProcessedFilePath]()
        for path in paths {
            processedPaths += utils.processZipPaths(path, parentDir: "")
        }

        guard let zip = zipOpen(zipFilePath, APPEND_STATUS_CREATE) else { return .ZipFail }
        defer { zipClose(zip, nil) }

        let chunkSize = 16384

        for path in processedPaths {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path.filePath, isDirectory: &isDir)
            guard !isDir.boolValue, let fileName = path.fileName else { continue }

            guard let readHandle = FileHandle(forReadingAtPath: path.filePath) else {
                return .ZipFail
            }
            defer { readHandle.closeFile() }

            var zipInfo = zip_fileinfo(
                tmz_date: tm_zip(tm_sec: 0, tm_min: 0, tm_hour: 0, tm_mday: 0, tm_mon: 0, tm_year: 0),
                dosDate: 0, internal_fa: 0, external_fa: 0
            )
            let entryName = path.fileDir.isEmpty ? fileName : path.fileDir + "/" + fileName

            if let pw = password, !pw.isEmpty {
                zipOpenNewFileInZip3(zip, entryName, &zipInfo, nil, 0, nil, 0, nil,
                                     Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0,
                                     -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY, pw, 0)
            } else {
                zipOpenNewFileInZip3(zip, entryName, &zipInfo, nil, 0, nil, 0, nil,
                                     Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0,
                                     -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY, nil, 0)
            }

            var data = readHandle.readData(ofLength: chunkSize)
            while !data.isEmpty {
                _ = data.withUnsafeBytes { ptr in
                    zipWriteInFileInZip(zip, ptr.baseAddress!, UInt32(data.count))
                }
                data = readHandle.readData(ofLength: chunkSize)
            }
            zipCloseFileInZip(zip)
        }

        return .ZipSuccess
    }
}
