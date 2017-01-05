# Perfect Zip [English](README.zh_CN.md)

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

Perfect Zip 压缩函数库

本 Perfect 项目模块封装了一个 C 函数库，并且提高简单的压缩和解压缩功能。

## 设置

如果您使用的是 MacOS 操作系统，请使用homebrew安装minizip：

```
brew install minizip
```

On Ubuntu, install minizip:

```
apt-get install libminizip-dev
```


## 在项目中增加本模块

请修改 Package.swift 文件增加以下依存关系：

``` swift
.Package(url: "https://github.com/PerfectlySoft/Perfect-Zip.git", majorVersion: 2, minor: 0)
```

## 运行

下面的程序展示了一段如何进行压缩：

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
print("压缩结果： \(ZipResult.description)")

```

以及解压缩文件：

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
print("解压缩结果： \(UnZipResult.description)")

```
