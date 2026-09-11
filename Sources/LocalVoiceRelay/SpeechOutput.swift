import Foundation
import AVFoundation
import RelayCore

@MainActor final class SpeechOutput {
    private var process: Process?
    private let playback = StreamingPlayback()
    private var cancelled = false
    private var generation = UUID()

    /// Installed voices for the selected language, best quality first. Enhanced and premium variants come from System Settings.
    static func voices(for language: AppLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.split(separator: "-").first == Substring(language.rawValue) }
            .sorted { (rank($0.quality), preference($0, language: language), $0.name, $0.identifier) < (rank($1.quality), preference($1, language: language), $1.name, $1.identifier) }
    }
    /// Prefer Kyoko in Japanese; otherwise use the best installed voice in the selected language.
    static func automaticVoice(for language: AppLanguage) -> AVSpeechSynthesisVoice? {
        let available = voices(for: language)
        return (language == .japanese ? available.first { $0.name == "Kyoko" } : nil) ?? available.first
    }
    private static func preference(_ voice: AVSpeechSynthesisVoice, language: AppLanguage) -> Int {
        // Prefer natural English voices over novelty voices at the same installed quality.
        guard language == .english else { return 0 }
        return ["Samantha", "Alex", "Daniel", "Karen", "Moira", "Tessa"].firstIndex(of: voice.name) ?? 6
    }
    static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 0
        case .enhanced: return 1
        default: return 2
        }
    }
    static func name(_ voice: AVSpeechSynthesisVoice) -> String { label(voice.name, quality: voice.quality) }
    static func label(_ name: String, quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return L10n.text("\(name)（プレミアム）")
        case .enhanced: return L10n.text("\(name)（拡張）")
        default: return name
        }
    }
    func warmup(settings: Settings, worker: LocalWorker) async throws {
        guard settings.ttsEngine == "qwen" else { return }
        try settings.validateSpeech()
        _ = try await worker.call(WorkerRequest.warmSpeech(settings: settings), python: settings.pythonPath)
    }
    func speak(_ text: String, settings: Settings, worker: LocalWorker,
               onSplit: (Int) -> Void = { _ in },
               onProgress: (SpeechLineProgress) -> Void = { _ in }, onStart: () -> Void = {}) async throws {
        try settings.validateSpeech()
        let run = UUID()
        generation = run
        cancelled = false
        // Both voices read the spoken form; the reply on screen keeps its Markdown.
        let spoken = SpeechText.forSpeech(text, language: settings.language)
        if settings.ttsEngine == "system" {
            try await speakWithSystemVoice(spoken, settings: settings, onStart: onStart)
        } else {
            try await speakWithQwen(spoken, settings: settings, worker: worker, run: run,
                                    onSplit: onSplit, onProgress: onProgress, onStart: onStart)
        }
    }
    private func speakWithSystemVoice(_ text: String, settings: Settings, onStart: () -> Void) async throws {
        guard let voice = Self.voices(for: settings.language).first(where: { $0.identifier == settings.systemVoiceID }) ?? Self.automaticVoice(for: settings.language) else {
            throw RelayError.message(L10n.text("日本語音声が未配置です。システム設定 → アクセシビリティ → 読み上げコンテンツで先に取得してください。"))
        }
        let source = try PrivateStorage.temporaryFile(extension: "txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(Self.systemSpeechText(text, volume: settings.speechVolume).utf8).write(to: source)
        // The identifier selects the exact quality variant; the display name alone would pick the compact voice.
        let process = OfflineProcess.sandboxed(Self.systemArguments(voice: voice.identifier, source: source.path, rate: settings.systemSpeechRate))
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
        guard !cancelled, process.terminationStatus == 0 else { throw RelayError.message(L10n.text("読み上げが停止したか、ローカル音声を利用できません。")) }
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
            try playback.enqueue(buffer, volume: Float(settings.speechVolume))
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
    /// macOS's volume command applies to this speech channel, leaving the system output volume alone.
    static func systemSpeechText(_ text: String, volume: Double) -> String {
        // Reply text must not introduce commands that override the selected volume or speaking rate.
        let literal = text.replacingOccurrences(of: "[", with: "［").replacingOccurrences(of: "]", with: "］")
        return "[[volm \(volume)]]" + literal
    }
    static func systemArguments(voice: String, source: String, rate: Double) -> [String] {
        var arguments = ["/usr/bin/say", "-v", voice, "-f", source]
        if rate > 0 { arguments += ["-r", String(rate)] }
        return arguments
    }
    func stop() {
        generation = UUID()
        cancelled = true
        process?.terminate()
        process = nil
        playback.stop()
    }
}
