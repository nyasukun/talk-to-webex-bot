import Foundation
import Darwin
import RelayCore

/// Serial stdio inference. The OS denies network access even if a dependency attempts a download.
final class LocalWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.localvoicerelay.worker")
    private let stateLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var activePython = ""
    private var generation = 0
    private var processGeneration = -1
    private var reader = WorkerResponseReader()

    func call(_ payload: [String: Any], python: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        let current = stateLock.withLock { generation }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.stateLock.withLock({ self.generation == current }) else { throw CancellationError() }
                    if self.process?.isRunning != true || self.activePython != python || self.processGeneration != current {
                        try self.launch(python: python); self.processGeneration = current
                    }
                    guard self.stateLock.withLock({ self.generation == current }) else {
                        if let process = self.process { Self.terminate(process) }; throw CancellationError()
                    }
                    guard let process = self.process, let input = self.input, let output = self.output else { throw RelayError.message("ローカル音声処理を起動できません。") }
                    let timeout = ["synthesize", "warm_speech", "next_speech"].contains(payload["action"] as? String ?? "") ? 600.0 : 180.0
                    let watchdog = DispatchWorkItem { Self.terminate(process) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    defer { watchdog.cancel() }
                    var data = try JSONSerialization.data(withJSONObject: payload); data.append(10)
                    try input.write(contentsOf: data)
                    let line: Data
                    do { line = try self.reader.readLine(from: output) }
                    catch { self.processGeneration = -1; Self.terminate(process); throw error }
                    guard self.stateLock.withLock({ self.generation == current }) else { throw CancellationError() }
                    guard !line.isEmpty, let result = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                        self.processGeneration = -1; Self.terminate(process)
                        throw RelayError.message("音声処理が終了しました。処理時間・メモリ・モデル配置を確認してください。")
                    }
                    if let error = result["error"] as? String { throw RelayError.message(error) }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func launch(python: String) throws {
        if let process { Self.terminate(process) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; reader = WorkerResponseReader()
        guard python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else {
            throw RelayError.message("Python環境がありません。scripts/setup-runtime.sh を実行してください。")
        }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("worker/relay_worker.py"), FileManager.default.fileExists(atPath: script.path) else {
            throw RelayError.message("音声処理がバンドルされていません。scripts/build.sh で.appをビルドしてください。")
        }
        let process = OfflineProcess.sandboxed([python, "-u", script.path]), stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        stateLock.withLock { self.process = process }
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        activePython = python
    }
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func shutdown() {
        let active = stateLock.withLock { generation += 1; return process }
        if let active { Self.terminate(active) }
    }
    deinit { if let process, process.isRunning { process.terminate() } }
}
