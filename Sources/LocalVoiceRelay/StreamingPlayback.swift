import AVFoundation
import RelayCore

@MainActor final class StreamingPlayback {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var generation = UUID()
    private(set) var queuedSeconds = 0.0
    private(set) var queuedLines = 0
    private(set) var started = false
    private let makeEngine: () -> AVAudioEngine

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) { self.makeEngine = makeEngine }

    static func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RelayError.message(L10n.text("再生用の音声を読み込めません。"))
        }
        try file.read(into: buffer)
        return buffer
    }
    func enqueue(_ buffer: AVAudioPCMBuffer) throws {
        let parts = try Self.playbackBuffers(buffer)
        if engine == nil {
            let engine = makeEngine(), node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            try engine.start()
            self.engine = engine
            self.node = node
        }
        guard node?.outputFormat(forBus: 0) == buffer.format else {
            throw RelayError.message(L10n.text("音声生成中に再生形式が変わりました。"))
        }
        let run = generation
        queuedLines += 1
        // Offline verification has no audio device to report dataPlayedBack.
        let completion: AVAudioPlayerNodeCompletionCallbackType = engine?.isInManualRenderingMode == true ? .dataRendered : .dataPlayedBack
        // Account for playback as it progresses, even when the worker returns a whole sentence.
        for (index, part) in parts.enumerated() {
            let duration = Double(part.frameLength) / part.format.sampleRate
            let completesLine = index == parts.count - 1
            queuedSeconds += duration
            node?.scheduleBuffer(part, completionCallbackType: completion) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    self.queuedSeconds = max(0, self.queuedSeconds - duration)
                    if self.queuedSeconds < 0.000_001 { self.queuedSeconds = 0 }
                    if completesLine { self.queuedLines = max(0, self.queuedLines - 1) }
                }
            }
        }
    }
    func start(onStart: () -> Void) {
        guard !started, queuedLines > 0 else { return }
        started = true
        onStart()
        node?.play()
    }
    static func playbackBuffers(_ source: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard source.frameLength > 0, let sourceChannels = source.floatChannelData, !source.format.isInterleaved else {
            throw RelayError.message(L10n.text("再生用のPCM形式が不正です。"))
        }
        let step = max(1, Int(source.format.sampleRate * 0.5))
        return try stride(from: 0, to: Int(source.frameLength), by: step).map { start in
            let count = min(step, Int(source.frameLength) - start)
            guard let part = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = part.floatChannelData else { throw RelayError.message(L10n.text("再生用メモリを確保できません。")) }
            part.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(source.format.channelCount) {
                channels[channel].update(from: sourceChannels[channel].advanced(by: start), count: count)
            }
            return part
        }
    }
    func stop() {
        generation = UUID()
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        queuedSeconds = 0
        queuedLines = 0
        started = false
    }
    func waitUntilBuffered(atMost seconds: Double, lines: Int = 0) async throws {
        let run = generation
        var progress = PlaybackProgress(remainingSeconds: queuedSeconds)
        while queuedSeconds > seconds || queuedLines > lines {
            try Task.checkCancellation()
            guard run == generation else { throw CancellationError() }
            guard started, engine?.isRunning == true, !progress.stalled(remainingSeconds: queuedSeconds) else {
                throw RelayError.message(L10n.text("音声の再生が進みません。出力デバイスを確認してください。"))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
