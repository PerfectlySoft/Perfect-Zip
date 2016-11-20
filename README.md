# Perfect Zip

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
        <img src="https://img.shields.io/badge/Swift-3.0-orange.svg?style=flat" alt="Swift 3.0">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-OS%20X%20%7C%20Linux%20-lightgray.svg?style=flat" alt="Platforms OS X | Linux">
    </a>
    <a href="http://perfect.org/licensing.html" target="_blank">
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

This Perfect module wraps the minizip C library and provides simple zip and unzip functionality.

## Setup

For MacOS insytall minizip using homebrew:

```
brew install minizip
```

On Ubuntu, install libminizip-dev:

```
apt-get install libminizip-dev
```

If libminizip-dev **cannot be found**:   
First, check that the universe repository is enabled by inspecting `/etc/apt/sources.list`

```
sudo nano /etc/apt/sources.list
```

If universe is not included then modify the file so that it does include the next line:

```
deb http://us.archive.ubuntu.com/ubuntu vivid main universe
```
And update the package list:

```
sudo apt-get update
```
Now repeating the first should succeed.

## Incluing in your project

Add this project as a dependency in your Package.swift file.

``` swift
.Package(url: "https://github.com/PerfectlySoft/Perfect-Zip.git", majorVersion: 2, minor: 0)
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
