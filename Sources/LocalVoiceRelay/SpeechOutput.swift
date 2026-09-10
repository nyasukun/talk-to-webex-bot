import Foundation
import AVFoundation
import RelayCore

@MainActor final class SpeechOutput {
    private var process: Process?
    private let playback = StreamingPlayback()
    private var cancelled = false
    private var generation = UUID()

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
    }
    static func name(_ voice: AVSpeechSynthesisVoice) -> String { voice.name }
    func warmup(settings: Settings, worker: LocalWorker) async throws {
        guard settings.ttsEngine == "qwen" else { return }
        _ = try await worker.call(WorkerRequest.warmSpeech(settings: settings), python: settings.pythonPath)
    }
    func speak(_ text: String, settings: Settings, worker: LocalWorker,
               onSplit: (Int) -> Void = { _ in },
               onProgress: (SpeechLineProgress) -> Void = { _ in }, onStart: () -> Void = {}) async throws {
        let run = UUID()
        generation = run
        cancelled = false
        if settings.ttsEngine == "system" {
            try await speakWithSystemVoice(text, settings: settings, onStart: onStart)
        } else {
            try await speakWithQwen(text, settings: settings, worker: worker, run: run,
                                    onSplit: onSplit, onProgress: onProgress, onStart: onStart)
        }
    }
    private func speakWithSystemVoice(_ text: String, settings: Settings, onStart: () -> Void) async throws {
        guard let voice = Self.voices.first(where: { $0.identifier == settings.systemVoiceID }) ?? Self.voices.first(where: { $0.name == "Kyoko" }) ?? Self.voices.first else {
            throw RelayError.message("日本語音声が未配置です。システム設定 → アクセシビリティ → 読み上げコンテンツで先に取得してください。")
        }
        let source = try PrivateStorage.temporaryFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(text.utf8).write(to: source)
        let process = OfflineProcess.sandboxed(["/usr/bin/say", "-v", Self.name(voice), "-f", source.path])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            if self.process === process { self.process = nil }
        }
        onStart()
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !cancelled, process.terminationStatus == 0 else { throw RelayError.message("読み上げが停止したか、ローカル音声を利用できません。") }
        self.process = nil
    }
    private func speakWithQwen(_ text: String, settings: Settings, worker: LocalWorker, run: UUID,
                               onSplit: (Int) -> Void, onProgress: (SpeechLineProgress) -> Void,
                               onStart: () -> Void) async throws {
        _ = try await worker.call(WorkerRequest.beginSpeech(text: text, settings: settings), python: settings.pythonPath)
        try await SpeechPipeline.run(next: { () async throws -> (AVAudioPCMBuffer, [String: Any])? in
            try Task.checkCancellation()
            guard !cancelled, generation == run else { throw CancellationError() }
            let output = try PrivateStorage.temporaryFile(extension: "wav")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await worker.call(WorkerRequest.nextSpeech(output: output.path), python: settings.pythonPath)
            try Task.checkCancellation()
            guard !cancelled, generation == run else { throw CancellationError() }
            if result["done"] as? Bool == true { return nil }
            if let count = result["resplits"] as? Int, count > 0 { onSplit(count) }
            return (try StreamingPlayback.read(output), result)
        }, enqueue: { buffer, result in
            let remaining = playback.queuedSeconds
            let ranOut = playback.started && playback.queuedLines == 0
            try playback.enqueue(buffer)
            onProgress(SpeechLineProgress(line: result["line_index"] as? Int ?? 0,
                                          total: result["line_count"] as? Int ?? 0,
                                          generationSeconds: result["generation_seconds"] as? Double ?? 0,
                                          audioSeconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                                          bufferedSeconds: remaining, bufferRanOut: ranOut))
        }, start: {
            playback.start(onStart: onStart)
        }, waitForCapacity: {
            try await playback.waitUntilBuffered(atMost: SpeechPipeline.maximumBufferedSeconds,
                                                 lines: SpeechPipeline.maximumBufferedLines)
        }, finish: {
            try await playback.waitUntilBuffered(atMost: 0)
        }, stop: {
            if generation == run { playback.stop() }
        })
    }
    func stop() {
        generation = UUID()
        cancelled = true
        process?.terminate()
        process = nil
        playback.stop()
    }
}
