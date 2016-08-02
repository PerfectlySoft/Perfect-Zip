//
//  main.swift
//  PerfectTemplate
//
//  Created by Kyle Jessup on 2015-11-05.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectLib

print("Starting Zip tester")

let zippy = Zip()

let thisSourceFile = "/Users/jonathanguthrie/Documents/development/tests/PerfectDocs.zip"
let thisSourceFile2 = "/Users/jonathanguthrie/Documents/development/tests/PerfectDocs2.zip"
let destinationDir = "/Users/jonathanguthrie/Documents/development/tests"

let UnZipResult = zippy.unzipFile(source: thisSourceFile, destination: destinationDir, overwrite: true)
print("Unzip Result: \(UnZipResult.description)")


//let ZipResult = zippy.zipFiles(paths: [destinationDir], zipFilePath: thisSourceFile2, overwrite: true, password: "")
//print("ZipResult Result: \(ZipResult.description)")


