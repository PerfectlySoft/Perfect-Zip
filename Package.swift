// swift-tools-version:4.0
import PackageDescription
let package = Package(
	name: "PerfectZip",
	products: [
		.library(name: "PerfectZip", targets: ["PerfectZip", "minizip"])
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/PerfectLib.git", from: "3.0.0"),
	],
	targets: [
		.target(name: "PerfectZip", dependencies: ["minizip", "PerfectLib"]),
		.target(name: "minizip"),
		.testTarget(name: "PerfectZipTests", dependencies: ["PerfectZip"])
	]
)
