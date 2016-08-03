//
//  zip.swift
//  ZipLib
//
//  Created by Jonathan Guthrie on 2016-07-28.
//
//

import PerfectLib
import minizip


// TODO: Doc comments

public class Zip {

	/**
	Unzip file

	- parameter source:			Local file path of zipped file. URL.
	- parameter destination:	Local file path to unzip to. URL.
	- parameter overwrite:		Overwrite bool.
	- parameter password:		Optional password if file is protected.

	- throws: Error if unzipping fails or if fail is not found.
	*/

	public func unzipFile(source: String, destination: String, overwrite: Bool, password: String = "") -> ZipStatus {

		// set source file and fail if it does not exist
		let theZip = File(source)
		defer {
			theZip.close()
		}
		guard theZip.exists == true else {
			return ZipStatus.FileNotFound
		}

		// if overwrite false and destination dir exists, fail
		let theDestination = Dir(destination)
		if overwrite == false {
			guard theDestination.exists == false else {
				return ZipStatus.ZipCannotOverwrite
			}
		}
		var ret: Int32 = 0
		var crc_ret: Int32 = 0
		let bufferSize: UInt32 = 4096
		var buffer = Array<CUnsignedChar>(repeating: 0, count: Int(bufferSize))


		// Begin unzipping
		let zip = unzOpen64(theZip.path)
		defer {
			unzClose(zip)
		}
		if unzGoToFirstFile(zip) != UNZ_OK {
			return ZipStatus.UnzipFail
		}
		repeat {
			//			if let cPassword = password as [Int8] { // wrong. TODO: FIX THIS
//				ret = unzOpenCurrentFilePassword(zip, cPassword)
//			}
//			else {
				ret = unzOpenCurrentFile(zip)
//			}
			if ret != UNZ_OK {
				return ZipStatus.UnzipFail
			}
			var fileInfo = unz_file_info64()
			memset(&fileInfo, 0, sizeof(unz_file_info.self))
			ret = unzGetCurrentFileInfo64(zip, &fileInfo, nil, 0, nil, 0, nil, 0)
			if ret != UNZ_OK {
				unzCloseCurrentFile(zip)
				return ZipStatus.UnzipFail
			}
			let fileNameSize = Int(fileInfo.size_filename) + 1
			let fileName = UnsafeMutablePointer<CChar>.allocate(capacity: fileNameSize)

			unzGetCurrentFileInfo64(zip, &fileInfo, fileName, UInt(fileNameSize), nil, 0, nil, 0)
			fileName[Int(fileInfo.size_filename)] = 0
			var pathString = String(cString:UnsafePointer<CChar>(fileName))

			var isDirectory = false

			let fileInfoSizeFileName = Int(fileInfo.size_filename-1)
			let fnstr  = String(cString:UnsafePointer<CChar>(fileName))

			if fileName[fileInfoSizeFileName] == 47 {
				isDirectory = true;
			}
			free(fileName)

			if pathString.characters.index(of: "\\") != nil {
				pathString = pathString.stringByReplacing(string: "\\", withString: "/")
				pathString = pathString.stringByReplacing(string: "//", withString: "/")
			}
			let fullPath = theDestination.path + pathString
			let thisFile = File(fullPath)
			defer {
				thisFile.close()
			}
			// note: ignoring creation date
			do {
				if isDirectory {
					if !fullPath.contains("__MACOSX") {
						let newDir = Dir(fullPath)
						try newDir.create()
					}
				}
				else {
					var parentDirectoryPathArray = fullPath.characters.split(separator: "/").map(String.init)
					parentDirectoryPathArray.removeLast()
					let parentDirectory = Dir(parentDirectoryPathArray.joined(separator: "/"))
					try parentDirectory.create()

				}
			} catch {}


			if thisFile.exists && !isDirectory && !overwrite {
				unzCloseCurrentFile(zip)
				ret = unzGoToNextFile(zip)
			}

			do {
				try thisFile.open(.truncate)
				let thisState = true
				while thisState == true {
					let readBytes = unzReadCurrentFile(zip, &buffer, bufferSize)
					if readBytes > 0 {
						try thisFile.write(bytes: buffer, dataPosition: 0, length: Int(readBytes))
					} else {
						break
					}
				}
			} catch {}

			crc_ret = unzCloseCurrentFile(zip)
			if crc_ret == UNZ_CRCERROR {
				return ZipStatus.UnzipFail
			}
			ret = unzGoToNextFile(zip)

		} while (ret == UNZ_OK && ret != UNZ_END_OF_LIST_OF_FILE)


		return ZipStatus.ZipSuccess
	}



	/**
	Zip files.

	- parameter paths:       Array of URL filepaths.
	- parameter zipFilePath: Destination URL, should lead to a .zip filepath.
	- parameter overwrite:	 Overwrite bool.
	- parameter password:    Password string. Optional.

	- throws: Error if zipping fails.

	*/
	public func zipFiles(paths: [String], zipFilePath: String, overwrite: Bool, password: String?) -> ZipStatus {
		let uilContainer = ZipUtilities()

		// Check whether a zip file exists at path.
		let thisZip = File(zipFilePath)
		defer {
			thisZip.close()
		}

		// make sure destination file is a .zip extension
		guard zipFilePath.hasSuffix(".zip") else {
			return ZipStatus.ZipFail
		}

		// check to make sure destination zip can be created or overwritten
		if overwrite == false {
			guard thisZip.exists == false else {
				return ZipStatus.ZipCannotOverwrite
			}
		}

		// check the specified directories or files exist
		for path in paths {
			let thisCheckFile = Dir(path)
//			print("workingDir: \(Dir.workingDir.path)")
//			print("thisCheckFile.exists: \(thisCheckFile.exists), \(thisCheckFile.path)")
			guard thisCheckFile.exists == true else {
				return ZipStatus.FileNotFound
			}
		}

		var processedPaths = [ProcessedFilePath]()
		for path in paths {
			// Process zip paths
			let parentDir = ""
			for p in uilContainer.processZipPaths(path, parentDir: parentDir) {
				processedPaths.append(p)
			}
		}
		// Zip set up
		let chunkSize = 16384

		// Begin Zipping
		let zip = zipOpen(zipFilePath, APPEND_STATUS_CREATE)
		for path in processedPaths {


			let filePath = path.filePath

			let thisFile = File(filePath)

			if !thisFile.isDir {
				do {
					try thisFile.open(.read)
				} catch {
					return ZipStatus.ZipFail
				}
				let fileName = path.fileName
				var zipInfo: zip_fileinfo = zip_fileinfo(tmz_date: tm_zip(tm_sec: 0, tm_min: 0, tm_hour: 0, tm_mday: 0, tm_mon: 0, tm_year: 0), dosDate: 0, internal_fa: 0, external_fa: 0)


				let buffer = malloc(chunkSize)
				if password != "", let fileName = fileName {
					zipOpenNewFileInZip3(zip, path.fileDir+"/"+fileName, &zipInfo, nil, 0, nil, 0, nil,Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0, -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY, password, 0)
				}
				else if let fileName = fileName {
					zipOpenNewFileInZip3(zip, path.fileDir+"/"+fileName, &zipInfo, nil, 0, nil, 0, nil,Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0, -MAX_WBITS, DEF_MEM_LEVEL, Z_DEFAULT_STRATEGY, nil, 0)
				}
				else {
					return ZipStatus.ZipFail
				}



				do {
					var bytes = try thisFile.readSomeBytes(count: chunkSize)
					while bytes.count > 0 {
						zipWriteInFileInZip(zip, bytes, UInt32(bytes.count))
						bytes = try thisFile.readSomeBytes(count: chunkSize)
					}
				} catch {}

				zipCloseFileInZip(zip)
				free(buffer)
				thisFile.close()
			}
		}
		zipClose(zip, nil)
		return ZipStatus.ZipSuccess
	}

}

