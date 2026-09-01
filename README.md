# Perfect Zip

<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.2-orange.svg?style=flat" alt="Swift 6.2">
    <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B-lightgray.svg?style=flat" alt="Platforms macOS 12+">
    <a href="LICENSE" target="_blank"><img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache"></a>
</p>

A thin Swift wrapper around a vendored `minizip` (including AES) linked against system `zlib`:
create an archive from a set of paths, or extract one, both with optional password support.
`Zip`, `ZipStatus`, and `ProcessedFilePath` are `Sendable`; the target builds under Swift 6
language mode. No async/await yet — synchronous, blocking file I/O.

No external SwiftPM dependencies — everything needed is built in-tree.

**Integration status:** standalone library — nothing else in this ecosystem depends on it yet.
Not deprecated, just not yet wired into a consumer.

The pre-Swift-6 version is preserved on the [`legacy`](../../tree/legacy) branch.

## Including in your project

Add this project as a dependency in your Package.swift file, then add `"PerfectZip"` to your target's `dependencies`.

``` swift
.package(url: "https://github.com/PerfectlySoft/Perfect-Zip.git", branch: "main")
```

## Running

The following will zip the specified directory:

``` swift
import PerfectZip

let zippy = Zip()

let thisZipFile = "/path/to/ZipFile.zip"
let sourceDir = "/path/to/files/"

let ZipResult = zippy.zipFiles(
	paths: [sourceDir], 
	zipFilePath: thisZipFile, 
	overwrite: true, password: ""
)
print("ZipResult Result: \(ZipResult.description)")

```

To unzip a file:

``` swift
import PerfectZip

let zippy = Zip()

let sourceDir = "/path/to/files/"
let thisZipFile = "/path/to/ZipFile.zip"

let UnZipResult = zippy.unzipFile(
	source: thisZipFile, 
	destination: sourceDir, 
	overwrite: true
)
print("Unzip Result: \(UnZipResult.description)")

```

## Further Information
For more information on the Perfect project, please visit [perfect.org](http://perfect.org).
