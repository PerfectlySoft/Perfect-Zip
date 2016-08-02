//
//  utilities.swift
//  ZipLib
//
//  Created by Jonathan Guthrie on 2016-08-02.
//
//

import PerfectLib
import Foundation

struct ZipUtilities {
	func processZipPaths(_ path: String, parentDir: String) -> [ProcessedFilePath]{
		var processedFilePaths = [ProcessedFilePath]()
		//	for path in paths {

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
		//	}
		return processedFilePaths
	}

	func lastPathComponent(_ path:String) -> String {
//		var pathArray = path.components(separatedBy: "/")
		var pathArray = path.characters.split(separator: "/").map(String.init)
		if pathArray.last! as String == "" {
			pathArray.removeLast()
		}
		return pathArray.last!
	}

}
