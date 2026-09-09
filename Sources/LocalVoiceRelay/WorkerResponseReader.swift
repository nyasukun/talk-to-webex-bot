import Foundation
import Darwin
import RelayCore

/// Buffered JSON Lines framing. Partial reads are expected; partial messages are never accepted.
struct WorkerResponseReader {
    private var pending = Data()
    let maximumBytes: Int
    init(maximumBytes: Int = 1_000_000) { self.maximumBytes = maximumBytes }

    mutating func readLine(from handle: FileHandle) throws -> Data {
        try readLine {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return Data(bytes.prefix(count))
            }
        }
    }

    mutating func readLine(nextChunk: () throws -> Data) throws -> Data {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                guard pending.distance(from: pending.startIndex, to: newline) <= maximumBytes else { throw tooLarge }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            guard pending.count <= maximumBytes else { throw tooLarge }
            let chunk = try nextChunk()
            guard !chunk.isEmpty else {
                throw RelayError.message("音声処理の応答が途中で終了しました。処理時間・メモリ・モデル配置を確認してください。")
            }
            pending.append(chunk)
        }
    }

    private var tooLarge: RelayError { .message("音声処理の出力が上限を超えました。") }
}
