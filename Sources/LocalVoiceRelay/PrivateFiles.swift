import Foundation
import Darwin
import RelayCore

/// Files contain private user data from their creation, including during replacement.
enum PrivateFiles {
    static func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw RelayError.message("保存先が通常のフォルダではありません。保存先を確認してください。")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func write(_ data: Data, to destination: URL) throws {
        try prepareDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func read(_ source: URL, maximumBytes: Int) throws -> Data {
        precondition(maximumBytes > 0 && maximumBytes < Int.max)
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= maximumBytes else {
            throw RelayError.message("保存ファイルの形式またはサイズが不正です。")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RelayError.message("保存ファイルが上限を超えています。") }
        return data
    }
}
