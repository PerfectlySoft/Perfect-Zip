//
//  utilities.swift
//  PerfectZip
//
//  Created by Jonathan Guthrie on 2016-08-02.
//
//
// ==========================================================================
//	loosely based on https://github.com/marmelroy/Zip
//	converted to Swift 3 and utilizing Perfect 2's directory and file objects
// ==========================================================================

import PerfectLib
import Foundation


/// Zip status type
public enum ZipStatus: Error {
	/// File not found
	case FileNotFound
	/// Unzip fail
	case UnzipFail
	/// Zip fail
	case ZipFail
	/// Cannot overwrite Destination
	case ZipCannotOverwrite
	/// No Error
	case ZipSuccess

	/// User readable description
	public var description: String {
		switch self {
		case .FileNotFound: return "File not found."
		case .UnzipFail: return "Failed to unzip file."
		case .ZipFail: return "Failed to zip file."
		case .ZipCannotOverwrite: return "Cannot overwrite destination file."
		case .ZipSuccess: return "Success."
		}
	}
}

/// Custom struct to hold required data
public struct ProcessedFilePath {
	/// full file path
	let filePath: String

	/// file directory path from root of zip
	let fileDir: String

	/// filename
	let fileName: String?

}


/// Generic holdall for some needed utilities
struct ZipUtilities {

	/// Recursive function that pulls all file paths and creates an array of ProcessedFilePath
	func processZipPaths(_ path: String, parentDir: String) -> [ProcessedFilePath]{
		var processedFilePaths = [ProcessedFilePath]()

		let thisFile = File(path)

		if thisFile.isDir == false {
			if lastPathComponent(path) != ".DS_Store" {
				let newpath = path.stringByReplacing(string: "//",withString: "/")

				let processedPath = ProcessedFilePath(filePath: newpath, fileDir: parentDir, fileName: lastPathComponent(newpath))
				processedFilePaths.append(processedPath)
			}
		}
		else if path.contains("__MACOSX") == false {
			let thisDir = Dir(thisFile.path)
			let thisNewParent = self.lastPathComponent(thisFile.path)
			do {
				try thisDir.forEachEntry(closure: {
					n in
					var newpath = thisFile.path + "/" + n
					newpath = newpath.stringByReplacing(string: "//",withString: "/")
					var newParent = thisNewParent
					if parentDir != "" {
						newParent = parentDir+"/"+thisNewParent
					}
					processedFilePaths += self.processZipPaths(newpath, parentDir: newParent)
				})
			} catch {}
		}
		return processedFilePaths
	}

	func lastPathComponent(_ path: String) -> String {
		var pathArray = path.split(separator: "/")
		if pathArray.last! == "" {
			pathArray.removeLast()
		}
		return String(pathArray.last!)
	}
}
