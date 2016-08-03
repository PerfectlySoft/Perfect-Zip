//
//  PerfectZipTests.swift
//  PerfectZip
//
//  Created by Jonathan Guthrie on 2016-07-28.
//	Copyright (C) 2016 PerfectlySoft, Inc.
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


import XCTest
import PerfectLib
@testable import PerfectZip
import minizip

class PerfectZipTests: XCTestCase {
	public var workingDir = ""

	override func setUp() {
		super.setUp()
		// setup code. called before the invocation of each test method in the class.

		self.workingDir = Dir.workingDir.path

		// create internal working dir for tests
		let workingTestDir = Dir("testDirectories")
		do {
			try workingTestDir.create()
			try workingTestDir.setAsWorkingDir()
		} catch {
			XCTFail()
		}

		// Create zip directory for zip tests
		let zipDir = Dir("toZip")
		do {
			try zipDir.create()
		} catch {
			XCTFail()
		}
		let zipDirInternal = Dir("toZip/internal")
		do {
			try zipDirInternal.create()
		} catch {
			XCTFail()
		}

		// create empty dir for tests
		let zipDirEmpty = Dir("isEmpty")
		do {
			try zipDirEmpty.create()
		} catch {
			XCTFail()
		}

		// create files for zip testing
		let txtFile1 = File("toZip/txt1.txt")
		do {
			try txtFile1.open(.truncate)
			defer {
				txtFile1.close()
			}
			try txtFile1.write(string: "Dvd pegacorn perfect storms darling I'm a. Nightmare dressed like a daydream 13 Management. 13 Management rosy cheeks a boatload. Rabbit hole haters gonna hate wildest dreams Lily Aldridge burn. Out pictures of you so. Basically Country Music Hall of Fame cherry lips. Castle mean Law & Order SVU dvd king Christmas vultures. Pretty lies moonman burn out write a song. About burning it down rose garden necklace Emma Stone. For me I think red baking silent screams. I know places day dream welcome to new york. Alive back from the dead discovered. Bulletproof cozy vultures rose garden Kanye. Pop king no headlights sun came up we both went. Mad wonderland cats refrigerator light tight little skirt trains no headlights. Cat stickers bad guys reckless cat stickers dvd players gonna.")
		} catch {
			XCTFail()
		}

		let txtFile2 = File("toZip/internal/txt2.txt")
		do {
			try txtFile2.open(.truncate)
			defer {
				txtFile2.close()
			}
			try txtFile2.write(string: "Forever everybody here burning it down. Shellback drunk on jealousy deep cut. Diet Coke heaven sink ships butterflies. National anthem permanent mark darling I'm a nightmare. Dressed like a daydream players gonna play girls and girls. Harry Styles flames pumpkin spice you look like Watch.")
		} catch {
			XCTFail()
		}

	}
	override func tearDown() {
		// teardown code. called after the invocation of each test method in the class.
		super.tearDown()
		let resetWorkingDir = Dir(self.workingDir)
		do {
			try resetWorkingDir.setAsWorkingDir()
		} catch {}

		let workingTestDir = Dir("testDirectories")

		do {
			self.deleteRecursive(workingTestDir, path: "testDirectories")
			try workingTestDir.delete()
		} catch {
			print(error)
			XCTFail()
		}

	}
	func deleteRecursive(_ dir:Dir, path: String){
		do {
			try dir.forEachEntry(closure: {
				n in
				let npath = path + "/"
				let thisFile = File(npath + n)
				if thisFile.isDir {
					let thisDir = Dir(npath + n)
					self.deleteRecursive(thisDir, path: npath + n)
					do {
						try thisDir.delete()
					} catch {
						print(error)
					}
				} else {
					thisFile.delete()
				}
			})
		} catch {
			print(error)
		}
	}

	func setWorkingDir() {
		let resetWorkingDir = Dir(self.workingDir)
		do {
			try resetWorkingDir.setAsWorkingDir()
		} catch {}
	}
/*
	tests:

	create zip
	X with bad source
	X with bad filename (dest)
	X with overwrite off (to fail)
	X with overwrite on (to pass)
	X all good (covered by the above)
*/

	// feeds deliberate bad path to zip.
	// should fail with .FileNotFound
	func testCreateWithBadPath() {
		setWorkingDir()
		let zippy = Zip()

		let sourceDir = "testDirectories/doesNotExist"
		let destinationZip = "testDirectories/testZip1.zip"

		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .FileNotFound)
		
	}

	// tries to create zip file without the .zip extension. immediate fail
	func testCreateWithBadZipName() {
		setWorkingDir()
		let zippy = Zip()

		let sourceDir = "testDirectories/doesNotExist"
		let destinationZip = "testDirectories/testZip1"

		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipFail)

	}

	// create zip, then try to overwrite with flag to false.
	func testCreateOverwriteOff() {
		setWorkingDir()

		let sourceDir = "testDirectories/toZip"
		let destinationZip = "testDirectories/testZip1.zip"

		// create file that we are going to try to overwrite
		let zippy = Zip()
		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipSuccess, ZipResult.description)

		// test to make sure it has failed
		let zippyTest = Zip()
		let ZipResultTest = zippyTest.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: false, password: "")
		XCTAssert(ZipResultTest == .ZipCannotOverwrite, ZipResultTest.description)
		
	}

	// create zip, then try to overwrite with flag true
	func testCreateOverwriteOn() {
		setWorkingDir()

		let sourceDir = "testDirectories/toZip"
		let destinationZip = "testDirectories/testZip1.zip"

		// create file that we are going to try to overwrite
		let zippy = Zip()
		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipSuccess, ZipResult.description)

		// test to make sure it has failed
		let zippyTest = Zip()
		let ZipResultTest = zippyTest.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResultTest == .ZipSuccess, ZipResultTest.description)
		
	}

	/*
	tests:

	unzip
	X with bad filename (source)
	X with overwrite off (to fail)
	X with overwrite on (to pass)
	- all good, then compare with specific contents from setup
	*/


	// feeds deliberate bad path to zip.
	// should fail with .FileNotFound
	func testUnzipWithBadPath() {
		setWorkingDir()
		let zippy = Zip()

		let sourceZip = "testDirectories/doesNotExist.zip"
		let destinationDir = "testDirectories/somewhere"

		let UnZipResult = zippy.unzipFile(source: sourceZip, destination: destinationDir, overwrite: true)
		XCTAssert(UnZipResult == .FileNotFound)

	}
	
	// creates a zip.
	// tries to unzip to an already existing location, should not be able to
	func testUnzipWithOverwriteOff() {
		setWorkingDir()

		let sourceZip = "testDirectories/testZip1.zip"
		let destinationDir = "testDirectories/somewhere"

		// create the dest dir so it would be "locked" out if overwrite off
		let lockDir = Dir(destinationDir)
		do {
			try lockDir.create()
		} catch {
			XCTAssert(false,"Could not create the directory for testUnzipWithOverwriteOff test")
		}


		// create file that we are going to try to extract
		let sourceDir = "testDirectories/toZip"
		let destinationZip = "testDirectories/testZip1.zip"
		let zippy = Zip()
		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipSuccess, ZipResult.description)


		let unZippy = Zip()
		let UnZipResult = unZippy.unzipFile(source: sourceZip, destination: destinationDir, overwrite: false)
		XCTAssert(UnZipResult == .ZipCannotOverwrite, UnZipResult.description)
		
	}


	// creates a zip.
	// tries to unzip to an already existing location, should be able to
	func testUnzipWithOverwriteOn() {
		setWorkingDir()

		let sourceZip = "testDirectories/testZip1.zip"
		let destinationDir = "testDirectories/somewhere"

		// create the dest dir so it would be "locked" out if overwrite off
		let lockDir = Dir(destinationDir)
		do {
			try lockDir.create()
		} catch {
			XCTAssert(false,"Could not create the directory for testUnzipWithOverwriteOff test")
		}


		// create file that we are going to try to extract
		let sourceDir = "testDirectories/toZip"
		let destinationZip = "testDirectories/testZip1.zip"
		let zippy = Zip()
		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipSuccess, ZipResult.description)


		let unZippy = Zip()
		let UnZipResult = unZippy.unzipFile(source: sourceZip, destination: destinationDir, overwrite: true)
		XCTAssert(UnZipResult == .ZipSuccess, UnZipResult.description)
		
	}
	
	// create zip, unzip and compare contents
	func testUnzipCompare() {
		setWorkingDir()

		// create file that we are going to try to extract
		let sourceDir = "testDirectories/toZip"
		let destinationZip = "testDirectories/testZip1.zip"
		let zippy = Zip()
		let ZipResult = zippy.zipFiles(paths: [sourceDir], zipFilePath: destinationZip, overwrite: true, password: "")
		XCTAssert(ZipResult == .ZipSuccess, ZipResult.description)

		// unzip
		let sourceZip = "testDirectories/testZip1.zip"
		let destinationDir = "testDirectories/somewhere"
		let unZippy = Zip()
		let UnZipResult = unZippy.unzipFile(source: sourceZip, destination: destinationDir, overwrite: true)
		XCTAssert(UnZipResult == .ZipSuccess, UnZipResult.description)

		// make arrays of files and directories
		setWorkingDir()
		let sourceDirDir = Dir(sourceDir)
		let destinationDirDir = Dir(destinationDir+"/toZip")

		let sourceDirArray = self.listRecursive(sourceDirDir, path: sourceDir, truncate: sourceDir)
		let destinationDirArray = self.listRecursive(destinationDirDir, path: destinationDir+"/toZip", truncate: destinationDir+"/toZip")

		XCTAssert(sourceDirArray == destinationDirArray, "Input and output contents of source and unzip do not match")
	}
	
	func listRecursive(_ dir:Dir, path: String, truncate: String) -> [String] {
		var arr = [String]()
		do {
			try dir.forEachEntry(closure: {
				n in
				if n.hasSuffix(".DS_Store") {
					return
				}

				let npath = path + "/"
				var compiledPath = npath + n
				compiledPath = compiledPath.stringByReplacing(string: "//", withString: "/")
				let truncatedPath = compiledPath.stringByReplacing(string: truncate, withString: "")
				let thisFile = File(compiledPath)

				if thisFile.isDir {
					let thisDir = Dir(compiledPath)
					arr.append(truncatedPath)
					let narray = self.listRecursive(thisDir, path: compiledPath, truncate: truncate)
					arr += narray
				} else {
					arr.append(truncatedPath)
				}
			})
		} catch {
			print("dir error (\(dir.path)): \(error)")
		}
		return arr
	}



	static var allTests : [(String, (PerfectZipTests) -> () throws -> Void)] {
		return [
			("testCreateWithBadPath", testCreateWithBadPath),
			("testCreateWithBadZipName", testCreateWithBadZipName),
			("testCreateOverwriteOff", testCreateOverwriteOff),
			("testCreateOverwriteOn", testCreateOverwriteOn),
			("testUnzipWithBadPath", testUnzipWithBadPath),
			("testUnzipWithOverwriteOff", testUnzipWithOverwriteOff),
			("testUnzipWithOverwriteOn", testUnzipWithOverwriteOn),
			("testUnzipCompare", testUnzipCompare)
		]
	}
}

