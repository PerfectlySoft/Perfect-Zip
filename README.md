# Perfect Zip [简体中文](README.zh_CN.md)

<p align="center">
    <a href="http://perfect.org/get-involved.html" target="_blank">
        <img src="http://perfect.org/assets/github/perfect_github_2_0_0.jpg" alt="Get Involed with Perfect!" width="854" />
    </a>
</p>

<p align="center">
    <a href="https://github.com/PerfectlySoft/Perfect" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_1_Star.jpg" alt="Star Perfect On Github" />
    </a>  
    <a href="http://stackoverflow.com/questions/tagged/perfect" target="_blank">
        <img src="http://www.perfect.org/github/perfect_gh_button_2_SO.jpg" alt="Stack Overflow" />
    </a>  
    <a href="https://twitter.com/perfectlysoft" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_3_twit.jpg" alt="Follow Perfect on Twitter" />
    </a>  
    <a href="http://perfect.ly" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_4_slack.jpg" alt="Join the Perfect Slack" />
    </a>
</p>

<p align="center">
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Swift-6.2-orange.svg?style=flat" alt="Swift 6.2">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-macOS%2026%2B-lightgray.svg?style=flat" alt="Platforms macOS 26+">
    </a>
    <a href="LICENSE" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache">
    </a>
    <a href="http://twitter.com/PerfectlySoft" target="_blank">
        <img src="https://img.shields.io/badge/Twitter-@PerfectlySoft-blue.svg?style=flat" alt="PerfectlySoft Twitter">
    </a>
    <a href="http://perfect.ly" target="_blank">
        <img src="http://perfect.ly/badge.svg" alt="Slack Status">
    </a>
</p>

Perfect Zip utility

This is a Swift 6.2 / macOS 26 resurrection of the original PerfectlySoft `Perfect-Zip` package, maintained in the [Perfect-Resurrection](https://github.com/taplin/Perfect-Resurrection) effort. The social/community badges above (get-involved banner, GitHub star, Stack Overflow, Twitter, Slack) still point at the original, long-dormant PerfectlySoft project rather than this fork — they're kept for attribution, not as an indication of where to file issues against this repo.

This module is a thin Swift wrapper around a vendored copy of the `minizip` C library (including its AES source, linked against system `zlib`) that provides simple zip and unzip functionality: create an archive from a set of paths, or extract an archive to a destination, both with optional password support. `Zip`, `ZipStatus`, and `ProcessedFilePath` are all `Sendable`, and the `PerfectZip` target builds under Swift 6 language mode (strict concurrency); there is no async/await API surface yet, all operations are synchronous, blocking file I/O.

**Requirements:** Swift 6.2 toolchain, macOS 26 or later. The package has no external SwiftPM dependencies — everything it needs (the vendored `minizip`/AES sources and the system `zlib` link) is built in-tree.

**Integration status:** Perfect-Zip is currently a standalone library — no other package in Perfect-Resurrection (including Perfect-Lasso) depends on it yet. It isn't deprecated or abandoned, just not yet wired into a consumer.

## Including in your project

Add this project as a dependency in your Package.swift file, then add `"PerfectZip"` to your target's `dependencies`.

``` swift
.package(url: "https://github.com/taplin/Perfect-Zip.git", from: "1.0.0")
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
