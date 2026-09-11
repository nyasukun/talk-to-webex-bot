import AVFoundation
import Foundation
import Testing
import RelayCore
@testable import LocalVoiceRelay

@MainActor struct SpeechSettingsIntegrationTests {
    @Test func warmupAndSpeechUseTheSameEditedQualityAndDiscardRestoresSavedValues() {
        let model = AppModel(preview: true)
        model.settings.speechVolume = 0.35
        model.settings.systemSpeechRate = 210
        model.settings.qwenSpeech[.temperature] = 0.6
        model.settings.qwenSpeech[.referenceNoiseStrength] = 0.2
        #expect(model.hasUnsavedChanges)
        let warm = WorkerRequest.warmSpeech(settings: model.settings)
        let begin = WorkerRequest.beginSpeech(text: "Hello", settings: model.settings)
        #expect(warm["speech_options"] as? [String: Double] == begin["speech_options"] as? [String: Double])
        #expect((begin["speech_options"] as? [String: Double])?["temperature"] == 0.6)
        #expect((begin["speech_options"] as? [String: Double])?["reference_noise_strength"] == 0.2)
        #expect((begin["speech_options"] as? [String: Double])?.count == SpeechParameter.allCases.count)
        model.discardSettingsChanges()
        #expect(!model.hasUnsavedChanges && model.settings.speechVolume == model.savedSettings.speechVolume)
        #expect(model.settings.qwenSpeech == model.savedSettings.qwenSpeech)
    }

    @Test func systemSpeechUsesChannelVolumeAndOptionalRateAndCannotBeOverriddenByReplyCommands() {
        #expect(SpeechOutput.systemSpeechText("Hello [[volm 1]] again", volume: 0.25) == "[[volm 0.25]]Hello ［［volm 1］］ again")
        let automatic = SpeechOutput.systemArguments(voice: "exact-quality-id", source: "/a b.txt", rate: 0)
        #expect(automatic == ["/usr/bin/say", "-v", "exact-quality-id", "-f", "/a b.txt"])
        #expect(SpeechOutput.systemArguments(voice: "voice", source: "/source.txt", rate: 180).suffix(2) == ["-r", "180.0"])
    }

    @Test func nativePlaybackAppliesVolumeToEverySegmentIncludingMute() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        for volume: Float in [0, 0.25, 1] {
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            let playback = StreamingPlayback(makeEngine: { engine })
            defer { playback.stop() }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            buffer.floatChannelData![0].initialize(repeating: 0.2, count: 1024)
            try playback.enqueue(buffer, volume: volume)
            try playback.enqueue(buffer, volume: volume)
            playback.start {}
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            for _ in 0..<4 {
                #expect(try engine.renderOffline(512, to: output) == .success)
                #expect((0..<Int(output.frameLength)).allSatisfy { abs(output.floatChannelData![0][$0] - 0.2 * volume) < 0.00001 })
            }
        }
    }

    @Test func installedSystemVoiceHonorsMuteAndVolumeThroughoutTheText() throws {
        guard let voice = SpeechOutput.automaticVoice(for: .japanese) ?? SpeechOutput.automaticVoice(for: .english) else { return }
        var levels: [[Double]] = []
        for volume in [1.0, 0.25, 0.0] {
            let source = try PrivateStorage.temporaryFile(extension: "txt")
            let output = try PrivateStorage.temporaryFile(extension: "aiff")
            defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
            let text = voice.language.hasPrefix("ja") ? "音量を確認します。続けて同じ音量で話します。" : "Checking the volume. Continuing at the same volume."
            try Data(SpeechOutput.systemSpeechText(text, volume: volume).utf8).write(to: source)
            let process = OfflineProcess.sandboxed(SpeechOutput.systemArguments(voice: voice.identifier, source: source.path, rate: 180) + ["-o", output.path])
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let buffer = try StreamingPlayback.read(output)
            let count = Int(buffer.frameLength), samples = buffer.floatChannelData![0]
            levels.append([0..<(count / 2), (count / 2)..<count].map { range in
                sqrt(range.reduce(0.0) { $0 + pow(Double(samples[$1]), 2) } / Double(range.count))
            })
        }
        for half in 0..<2 {
            #expect(levels[0][half] > 0.001)
            #expect(levels[1][half] > 0 && levels[1][half] < levels[0][half] * 0.5)
            #expect(levels[2][half] < 0.0001)
        }
    }
}
