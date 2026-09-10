import AVFoundation
import Foundation
import RelayCore

final class AudioRecorder: @unchecked Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let truncated: Bool
    }
    private var engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    @MainActor private(set) var isCapturing = false
    @MainActor private(set) var inputFormat = (rate: 0.0, channels: 0.0)
    private let queue = DispatchQueue(label: "org.localvoicerelay.audio")
    private var samples: [Float] = [], preRoll: [Float] = []
    private var silence = 0, voiced = 0
    private var generation = 0
    private var tapInstalled = false
    var onChunk: (@Sendable (Chunk) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onConfigurationChange: (@Sendable () -> Void)?
    private var reportedConversionError = false

    @MainActor func start(silenceSeconds: Double, minimumRMS: Double, voiceProcessing: Bool = false, diagnostic: Bool = false) async throws {
        try Permissions.requireMicrophone()
        try Task.checkCancellation()
        stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(voiceProcessing)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw RelayError.message(L10n.text("マイクの音声形式に対応できません。")) }
        inputFormat = (format.sampleRate, Double(format.channelCount))
        let current = queue.sync { generation }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate + 64)) else { return }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, let channel = converted.floatChannelData?[0] else {
                self.queue.async {
                    guard self.generation == current, !self.reportedConversionError else { return }
                    self.reportedConversionError = true
                    self.onError?(L10n.text("マイク音声の変換に失敗しました。入力デバイスを確認し、Macの追加音声処理を無効にして再開してください。"))
                }
                return
            }
            let floats = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            self.queue.async {
                guard self.generation == current, !floats.isEmpty else { return }
                let rms = sqrt(floats.reduce(Float(0)) { $0 + $1 * $1 } / Float(floats.count))
                self.onLevel?(min(1, rms * 15))
                if diagnostic {
                    let remaining = 6 * 16000 - self.samples.count
                    if remaining > 0 { self.samples += floats.prefix(remaining) }
                    return
                }
                let isVoiced = rms >= Float(minimumRMS)
                if self.samples.isEmpty {
                    if isVoiced {
                        self.samples = self.preRoll
                        self.voiced = 0
                    }
                    else {
                        self.preRoll += floats
                        self.preRoll = Array(self.preRoll.suffix(8000))
                        return
                    }
                }
                self.samples += floats
                if isVoiced {
                    self.silence = 0
                    self.voiced += floats.count
                }
                else { self.silence += floats.count }
                let truncated = self.samples.count >= 25 * 16000
                if self.silence >= Int(silenceSeconds * 16000) || truncated {
                    if self.voiced >= 4000 { self.onChunk?(Chunk(samples: self.samples, truncated: truncated)) }
                    self.samples = []
                    self.preRoll = []
                    self.voiced = 0
                    self.silence = 0
                }
            }
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                // The engine must not be torn down synchronously on its internal notification queue.
                Task { @MainActor in
                    guard let self, self.isCapturing, !self.engine.isRunning else { return }
                    self.onConfigurationChange?()
                }
            }
        }
        catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }
    @MainActor func stop() {
        isCapturing = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        queue.sync {
            generation += 1
            samples = []
            preRoll = []
            silence = 0
            voiced = 0
            reportedConversionError = false
        }
    }
    @MainActor func finishDiagnostic() -> [Float] {
        engine.stop()
        let result = queue.sync { samples }
        stop()
        return result
    }
    static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw RelayError.message(L10n.text("録音が空です。")) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let pointer = buffer.floatChannelData?[0] else { throw RelayError.message(L10n.text("録音バッファを作成できません。")) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try file.write(from: buffer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func importReference(from source: URL, to target: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard (3...30).contains(seconds), let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 24000 + 1024)) else {
            throw RelayError.message(L10n.text("参照音声は3〜30秒の音声ファイルを選んでください。"))
        }
        try file.read(into: input)
        var supplied = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { throw RelayError.message(L10n.text("参照音声をWAVに変換できません。")) }
        let destination = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try destination.write(from: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
