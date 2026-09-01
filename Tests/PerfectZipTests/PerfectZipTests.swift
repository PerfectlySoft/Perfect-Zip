import Testing
import Foundation
@testable import PerfectZip

@Suite(.serialized)
struct PerfectZipTests {

    // MARK: - Setup helpers

    private func makeTempDir() throws -> (root: URL, toZip: URL, zip: String, dest: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PerfectZipTests_\(UUID().uuidString)")
        let toZip = root.appendingPathComponent("toZip")
        let internal_ = toZip.appendingPathComponent("internal")

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: toZip, withIntermediateDirectories: true)
        try fm.createDirectory(at: internal_, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("isEmpty"), withIntermediateDirectories: true)

        let txt1 = "Dvd pegacorn perfect storms darling I'm a nightmare dressed like a daydream."
        let txt2 = "Forever everybody here burning it down. Shellback drunk on jealousy deep cut."

        try txt1.write(to: toZip.appendingPathComponent("txt1.txt"), atomically: true, encoding: .utf8)
        try txt2.write(to: internal_.appendingPathComponent("txt2.txt"), atomically: true, encoding: .utf8)

        let zipPath = root.appendingPathComponent("testZip1.zip").path
        let destPath = root.appendingPathComponent("somewhere").path
        return (root, toZip, zipPath, destPath)
    }

    private func listPaths(in dir: URL) -> Set<String> {
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        return Set(paths.filter { !$0.hasSuffix(".DS_Store") && !$0.hasPrefix("__MACOSX") })
    }

    // MARK: - Zip tests

    @Test func createWithBadPath() throws {
        let (root, _, _, _) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = Zip().zipFiles(
            paths: [root.appendingPathComponent("doesNotExist").path],
            zipFilePath: root.appendingPathComponent("out.zip").path,
            overwrite: true, password: ""
        )
        #expect(result == .FileNotFound)
    }

    @Test func createWithBadZipName() throws {
        let (root, _, _, _) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = Zip().zipFiles(
            paths: [root.appendingPathComponent("doesNotExist").path],
            zipFilePath: root.appendingPathComponent("testZip1").path, // no .zip
            overwrite: true, password: ""
        )
        #expect(result == .ZipFail)
    }

    @Test func createOverwriteOff() throws {
        let (root, toZip, zipPath, _) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(first == .ZipSuccess, "\(first.description)")

        let second = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: false, password: "")
        #expect(second == .ZipCannotOverwrite, "\(second.description)")
    }

    @Test func createOverwriteOn() throws {
        let (root, toZip, zipPath, _) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(first == .ZipSuccess, "\(first.description)")

        let second = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(second == .ZipSuccess, "\(second.description)")
    }

    // MARK: - Unzip tests

    @Test func unzipWithBadPath() throws {
        let (root, _, _, dest) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = Zip().unzipFile(
            source: root.appendingPathComponent("doesNotExist.zip").path,
            destination: dest, overwrite: true
        )
        #expect(result == .FileNotFound)
    }

    @Test func unzipOverwriteOff() throws {
        let (root, toZip, zipPath, dest) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let zipResult = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(zipResult == .ZipSuccess, "\(zipResult.description)")

        let unzipResult = Zip().unzipFile(source: zipPath, destination: dest, overwrite: false)
        #expect(unzipResult == .ZipCannotOverwrite, "\(unzipResult.description)")
    }

    @Test func unzipOverwriteOn() throws {
        let (root, toZip, zipPath, dest) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let zipResult = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(zipResult == .ZipSuccess, "\(zipResult.description)")

        let unzipResult = Zip().unzipFile(source: zipPath, destination: dest, overwrite: true)
        #expect(unzipResult == .ZipSuccess, "\(unzipResult.description)")
    }

    @Test func unzipCompare() throws {
        let (root, toZip, zipPath, dest) = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipResult = Zip().zipFiles(paths: [toZip.path], zipFilePath: zipPath, overwrite: true, password: "")
        #expect(zipResult == .ZipSuccess, "\(zipResult.description)")

        let unzipResult = Zip().unzipFile(source: zipPath, destination: dest, overwrite: true)
        #expect(unzipResult == .ZipSuccess, "\(unzipResult.description)")

        // The zip archive contains a "toZip/" prefix from processZipPaths, so unzipped tree is dest/toZip/
        let destToZip = URL(fileURLWithPath: dest).appendingPathComponent("toZip")
        let sourcePaths = listPaths(in: toZip)
        let destPaths   = listPaths(in: destToZip)

        #expect(sourcePaths == destPaths, "Source and unzipped file lists differ: \(sourcePaths.symmetricDifference(destPaths))")
    }
}
