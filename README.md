# Perfect Zip
Perfect Zip utility

This Perfect module wraps the minizip C library and provides simple zip and unzip functionality.

## Incluing in your project

Add this project as a dependency in your Package.swift file.

``` swift
.Package(url: "https://github.com/PerfectlySoft/Perfect-Zip.git", versions: Version(0,0,0)..<Version(10,0,0))
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
	source: sourceDir, 
	destination: thisZipFile, 
	overwrite: true
)
print("Unzip Result: \(UnZipResult.description)")

```