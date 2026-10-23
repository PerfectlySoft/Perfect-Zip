// swift-tools-version: 6.2
// libFuzzer harness for PerfectZip's unzip path. Linux only (Apple toolchains ship no libFuzzer):
//
//   cd Fuzz
//   swift build -c release -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library
//   mkdir -p corpus && cp some/*.zip corpus/
//   .build/release/FuzzUnzip corpus -max_total_time=600 -max_len=200000
import PackageDescription

let package = Package(
    name: "PerfectZipFuzz",
    dependencies: [.package(name: "PerfectZip", path: "..")],
    targets: [
        .executableTarget(
            name: "FuzzUnzip",
            dependencies: [.product(name: "PerfectZip", package: "PerfectZip")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
