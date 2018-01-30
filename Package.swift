// swift-tools-version:4.0
// Generated automatically by Perfect Assistant 2
// Date: 2017-10-17 16:49:36 +0000
import PackageDescription

let package = Package(
	name: "PerfectZip",
	products: [
		.library(name: "PerfectZip", targets: ["PerfectZip", "minizip"])
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect.git", "3.0.0"..<"4.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CZlib-src.git", from: "0.0.1")
	],
	targets: [
		.target(name: "PerfectZip", dependencies: ["minizip", "PerfectLib"]),
		.target(name: "minizip", dependencies: ["PerfectCZlib"]),
		.testTarget(name: "PerfectZipTests", dependencies: ["PerfectZip"])
	]
)
