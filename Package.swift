// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectZip",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PerfectZip", targets: ["PerfectZip", "minizip"]),
    ],
    targets: [
        .target(
            name: "PerfectZip",
            dependencies: ["minizip"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "minizip",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "PerfectZipTests",
            dependencies: ["PerfectZip"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
