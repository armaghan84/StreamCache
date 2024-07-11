//
//  FileHandler.swift
//
//
//  Created by Armaghan on 11/07/2024.
//

import Foundation
final class FileHandler {
    private let filePath: String
    private lazy var readHandle = FileHandle(forReadingAtPath: filePath)
    private lazy var writeHandle = FileHandle(forWritingAtPath: filePath)

    private let lock = NSLock()

    // MARK: Init

    init(filePath: String) {
        self.filePath = filePath
        self.createFile()
    }
    func createFile() {
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        } else {
            print("MediaFileHandle warning: File already exists at \(filePath).")
        }
    }
    deinit {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        close()
    }
}

// MARK: Internal methods

extension FileHandler {
    var attributes: [FileAttributeKey : Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: filePath)
        } catch let error as NSError {
            print("FileAttribute error: \(error)")
        }
        return nil
    }

    var fileSize: Int {
        return attributes?[.size] as? Int ?? 0
    }

    func readData(withOffset offset: Int, forLength length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        readHandle?.seek(toFileOffset: UInt64(offset))
        return readHandle?.readData(ofLength: length)
    }

    func append(data: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard let writeHandle = writeHandle else { return }

        writeHandle.seekToEndOfFile()
        writeHandle.write(data)
    }

    func synchronize() {
        lock.lock()
        defer { lock.unlock() }

        guard let writeHandle = writeHandle else { return }

        writeHandle.synchronizeFile()
    }

    func close() {
        readHandle?.closeFile()
        writeHandle?.closeFile()
    }

    func deleteFile() {
        do {
            try FileManager.default.removeItem(atPath: filePath)
        } catch let error {
            print("File deletion error: \(error)")
        }
    }
    func setFileExtendedAttribute() {
        do {
            // Assuming `downloadedFileURL` is the URL of the downloaded file
            try setExtendedAttribute(for: URL(string: self.filePath)!, key: "fullyDownloaded", value: "true")
        } catch {
            print("Error setting file attribute: \(error)")
        }
    }
    func setExtendedAttribute(for url: URL, key: String, value: String) throws {
        try url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath = fileSystemPath else { return }
            let data = value.data(using: .utf8)!
            let result = data.withUnsafeBytes {
                setxattr(fileSystemPath, key, $0.baseAddress, data.count, 0, 0)
            }
            if result != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }
        }
    }
}
    // MARK: - Helper Methods
extension FileHandler {
    func deleteAllMP4Files() {
        let directoryPath = (filePath as NSString).deletingLastPathComponent
        let fileManager = FileManager.default

        do {
            let files = try fileManager.contentsOfDirectory(atPath: directoryPath)
            for file in files where file.hasSuffix(".mp4") {
                let fileToDelete = (directoryPath as NSString).appendingPathComponent(file)
                try fileManager.removeItem(atPath: fileToDelete)
                print("Deleted file: \(fileToDelete)")
            }
        } catch {
            print("Error while deleting mp4 files: \(error)")
        }
    }
}
