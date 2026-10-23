// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectZip",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PerfectZip", targets: ["PerfectZip"]),
    ],
    targets: [
        .target(
            name: "PerfectZip",
            dependencies: ["CZlib"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The system zlib, used for deflate, inflate and CRC-32 only.
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [.apt(["zlib1g-dev"])]
        ),
        .testTarget(
            name: "PerfectZipTests",
            dependencies: ["PerfectZip"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
