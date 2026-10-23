import Foundation
import PerfectZip

// Small limits so a valid-but-huge mutated archive cannot fill the disk.
private let zip = Zip(limits: ZipLimits(maxTotalUncompressedSize: 64 << 20, maxCompressionRatio: 2000))
private let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("perfectzip-fuzz-\(getpid())").path

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let archive = root + ".zip"
    _ = FileManager.default.createFile(atPath: archive, contents: Data(bytes: data, count: size))
    _ = zip.unzipFile(source: archive, destination: root, overwrite: true, password: "pw")
    try? FileManager.default.removeItem(atPath: root)
    return 0
}
