import Testing
import Foundation
import AVFoundation
@testable import LocalVoiceRelay

@MainActor struct SpeechPipelineTests {
    @Test func nativePlayerPrerollsAndAppendsLinesWithoutLosingSamples() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let playback = StreamingPlayback(makeEngine: { engine })
        defer { playback.stop() }
        func line(_ value: Float, _ count: Int) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].initialize(repeating: value, count: count)
            return buffer
        }
        let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        try playback.enqueue(line(0.1, 18000))
        try playback.enqueue(line(0.2, 12000))
        #expect(!playback.started && playback.queuedLines == 2)
        _ = try engine.renderOffline(512, to: rendered)
        #expect((0..<Int(rendered.frameLength)).allSatisfy { rendered.floatChannelData![0][$0] == 0 })
        var starts = 0
        playback.start { starts += 1 }
        playback.start { starts += 1 }
        var samples: [Float] = []
        for index in 0..<80 {
            if index == 12 { try playback.enqueue(line(0.3, 8000)) }
            let status = try engine.renderOffline(512, to: rendered)
            #expect(status == .success)
            samples += Array(UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength)))
        }
        let expected = Array(repeating: Float(0.1), count: 18000) + Array(repeating: Float(0.2), count: 12000) + Array(repeating: Float(0.3), count: 8000)
        #expect(samples.count >= expected.count)
        #expect(zip(samples, expected).allSatisfy { abs($0 - $1) < 0.00001 })
        for _ in 0..<100 where playback.queuedLines > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(starts == 1 && playback.queuedLines == 0 && playback.queuedSeconds == 0)
    }

    @Test func startsBeforeRequestingTheSecondLineAndGeneratesAheadDuringPlayback() async throws {
        var requested = 0, enqueued: [Int] = [], atStart: [Int] = [], playingWhileGenerating: [Int] = []
        var playing = false, capacityWaits = 0, finished = false, stopped = false
        try await SpeechPipeline.run(next: { () async -> Int? in
            requested += 1
            if playing { playingWhileGenerating.append(requested) }
            return requested <= 5 ? requested : nil
        }, enqueue: { enqueued.append($0) }, start: {
            atStart = enqueued; playing = true
        }, waitForCapacity: { capacityWaits += 1 }, finish: {
            finished = true
        }, stop: { stopped = true })
        #expect(atStart == [1])
        #expect(enqueued == [1, 2, 3, 4, 5])
        #expect(playingWhileGenerating == [2, 3, 4, 5, 6])
        #expect(capacityWaits == 5)
        #expect(finished && stopped)
    }

    @Test func singleLineAndEmptyInputDoNotWaitForANonexistentSecondLine() async throws {
        for count in [0, 1] {
            var requested = 0, starts = 0, finishes = 0, stops = 0, waits = 0
            try await SpeechPipeline.run(next: { () async -> Int? in
                requested += 1; return requested <= count ? requested : nil
            }, enqueue: { _ in }, start: { starts += 1 }, waitForCapacity: {
                waits += 1
            }, finish: { finishes += 1 }, stop: { stops += 1 })
            #expect(starts == count && finishes == count && stops == 1)
            #expect(waits == count)
        }
    }

    @Test func failedGenerationDiscardsQueuedAudioBeforeOrAfterStart() async {
        enum Failure: Error { case generation }
        for failAt in [1, 2, 4] {
            var requested = 0, queued: [Int] = [], heardStart = false, stopped = false
            do {
                try await SpeechPipeline.run(next: { () async throws -> Int? in
                    requested += 1
                    if requested == failAt { throw Failure.generation }
                    return requested
                }, enqueue: { queued.append($0) }, start: { heardStart = true }, waitForCapacity: {}, finish: {
                    Issue.record("A failed generator cannot finish normally.")
                }, stop: { queued = []; stopped = true })
                Issue.record("Expected generation failure.")
            } catch {}
            #expect(requested == failAt && stopped && queued.isEmpty)
            #expect(heardStart == (failAt > 1))
        }
    }

    @Test func cancellationDuringGenerationOrCapacityWaitDoesNotEnqueueOrReadMore() async {
        for cancelAtCapacity in [false, true] {
            var requested = 0, enqueued: [Int] = [], stopped = false
            let task = Task { @MainActor in
                try await SpeechPipeline.run(next: { () async -> Int? in
                    requested += 1
                    if !cancelAtCapacity { withUnsafeCurrentTask { $0?.cancel() } }
                    return requested
                }, enqueue: { enqueued.append($0) }, start: {}, waitForCapacity: {
                    withUnsafeCurrentTask { $0?.cancel() }
                }, finish: {}, stop: { stopped = true })
            }
            do { try await task.value; Issue.record("Expected cancellation.") }
            catch { #expect(error is CancellationError) }
            #expect(stopped)
            #expect(requested == 1)
            #expect(enqueued == (cancelAtCapacity ? [1] : []))
        }
    }

    @Test func aheadBufferCoversASlowLineAndRemainsBounded() async throws {
        // Virtual audio time: line 3 takes longer than the old three-second reserve.
        let durations = [2.0, 5, 8, 9, 10, 6, 7]
        let generationTimes = [0.3, 0.6, 4.5, 1.5, 2, 1.5, 2]
        var now = 0.0, started = false, requested = 0, peakLines = 0, gaps = 0
        var queued: [(line: Int, end: Double)] = [], heard: [Int] = []
        func advance(_ seconds: Double) {
            now += seconds
            while started, let first = queued.first, first.end <= now {
                heard.append(first.line); queued.removeFirst()
            }
        }
        try await SpeechPipeline.run(next: { () async -> Int? in
            guard requested < durations.count else { return nil }
            advance(generationTimes[requested]); requested += 1
            return requested - 1
        }, enqueue: { line in
            if started && queued.isEmpty { gaps += 1 }
            let end = (queued.last?.end ?? now) + durations[line]
            queued.append((line, end)); peakLines = max(peakLines, queued.count)
        }, start: {
            started = true
            // Before start, generation time did not consume prepared audio.
            var end = now
            queued = queued.map { item in end += durations[item.line]; return (item.line, end) }
        }, waitForCapacity: {
            while queued.count > SpeechPipeline.maximumBufferedLines || (queued.last?.end ?? now) - now > SpeechPipeline.maximumBufferedSeconds {
                let lineDelay = queued.count > SpeechPipeline.maximumBufferedLines ? queued.first!.end - now : 0
                let timeDelay = max(0, queued.last!.end - now - SpeechPipeline.maximumBufferedSeconds)
                advance(max(lineDelay, timeDelay))
            }
        }, finish: {
            advance((queued.last?.end ?? now) - now)
        }, stop: { queued = [] })
        #expect(gaps == 0)
        #expect(heard == Array(durations.indices))
        #expect(peakLines <= SpeechPipeline.maximumBufferedLines + 1)
    }

    @Test func longPlaybackTimesOutOnlyWhenProgressStops() {
        let beginning = ContinuousClock.now
        var progress = PlaybackProgress(remainingSeconds: 80, now: beginning)
        let first = progress.stalled(remainingSeconds: 55, now: beginning.advanced(by: .seconds(25)))
        let second = progress.stalled(remainingSeconds: 30, now: beginning.advanced(by: .seconds(50)))
        let third = progress.stalled(remainingSeconds: 5, now: beginning.advanced(by: .seconds(75)))
        let stuck = progress.stalled(remainingSeconds: 5, now: beginning.advanced(by: .seconds(105)))
        #expect(!first && !second && !third && stuck)
    }
}
