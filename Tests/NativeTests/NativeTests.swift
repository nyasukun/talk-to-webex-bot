import Testing
import AppKit
import AVFoundation
import RelayCore
@testable import LocalVoiceRelay

struct NativeTests {
    @Test @MainActor func sentencePlaybackBuffersPreserveEverySampleAndChannel() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 2)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 30001)!
        source.frameLength = 30001
        for channel in 0..<2 {
            for frame in 0..<30001 { source.floatChannelData![channel][frame] = Float(frame + channel) / 40000 }
        }
        let parts = try StreamingPlayback.playbackBuffers(source)
        #expect(parts.map(\.frameLength) == [12000, 12000, 6001])
        for channel in 0..<2 {
            let combined = parts.flatMap { Array(UnsafeBufferPointer(start: $0.floatChannelData![channel], count: Int($0.frameLength))) }
            #expect(combined == Array(UnsafeBufferPointer(start: source.floatChannelData![channel], count: 30001)))
        }
    }
    @Test func sonarIsQuietAndHasSilentInterval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WaitingSound.wave().write(to: url)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        #expect(file.length == 72000)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #expect(samples.prefix(10800).contains { abs($0) > 0.1 })
        #expect(samples.allSatisfy { $0.isFinite && abs($0) < 0.5 })
        #expect(samples.dropFirst(10800).allSatisfy { $0 == 0 })
    }
    @Test @MainActor func japaneseVisionOCR() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 160,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 160).fill()
        let text = "音声アシスタントの動作確認"
        (text as NSString).draw(at: NSPoint(x: 40, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let recognized = try ScreenContext.recognize(bitmap.cgImage!)
        #expect(recognized.contains(text))
    }

    @Test func pcmConversionAndPrivatePermissions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frequency = 2.0 * Double.pi * 440.0 / 16000.0
        let samples: [Float] = (0..<16000).map { Float(sin(Double($0) * frequency) * 0.1) }
        try AudioRecorder.write(samples, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 16000)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(throws: (any Error).self) { try AudioRecorder.write([], to: url) }
    }
    @Test func referenceImportResamplesAndRejectsShortInput() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        try AudioRecorder.write(Array(repeating: 0.1, count: 16000), to: source)
        #expect(throws: (any Error).self) { try AudioRecorder.importReference(from: source, to: target) }
        try AudioRecorder.write(Array(repeating: 0.1, count: 64000), to: source)
        try AudioRecorder.importReference(from: source, to: target)
        let converted = try AVAudioFile(forReading: target)
        #expect(converted.fileFormat.sampleRate == 24000)
        #expect(converted.fileFormat.channelCount == 1)
        #expect(abs(Double(converted.length) / 24000.0 - 4.0) < 0.01)
    }

    @Test func permissionPreflightRequiresOnlyEnabledFeatures() throws {
        let audioOnly = PermissionSnapshot(microphone: .allowed, screen: false)
        try audioOnly.require(includeScreen: false)
        #expect(audioOnly.missing(includeScreen: false).isEmpty)
        #expect(throws: (any Error).self) { try audioOnly.require(includeScreen: true) }
        for mic in [PermissionSnapshot.Microphone.undecided, .denied, .restricted] {
            let absent = PermissionSnapshot(microphone: mic, screen: false)
            #expect(absent.missing(includeScreen: true).count == 2)
            #expect(throws: (any Error).self) { try absent.require(includeScreen: false) }
        }
        try PermissionSnapshot(microphone: .allowed, screen: true).require(includeScreen: true)
    }

}
