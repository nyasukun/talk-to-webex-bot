import Testing
import Foundation
@testable import RelayCore

struct UtteranceContinuationTests {
    private let start = Date(timeIntervalSince1970: 1000)
    private func interval(_ from: Double, _ to: Double) -> SpeechInterval {
        SpeechInterval(startedAt: start.addingTimeInterval(from), lastVoiceAt: start.addingTimeInterval(to))
    }

    @Test func sendsAtShortSilenceAndRetainsCaptureTimesWithoutStoppingCapture() throws {
        var audio = AudioSegmenter()
        let voice = [Float](repeating: 0.1, count: 1600), silence = [Float](repeating: 0, count: 1600)
        for i in 1...10 {
            let output = audio.ingest(voice, isVoiced: true, endingAt: start.addingTimeInterval(Double(i) / 10), silenceSeconds: 1.2)
            #expect(output == nil)
        }
        for i in 11...21 {
            let output = audio.ingest(silence, isVoiced: false, endingAt: start.addingTimeInterval(Double(i) / 10), silenceSeconds: 1.2)
            #expect(output == nil)
        }
        let firstOutput = audio.ingest(silence, isVoiced: false, endingAt: start.addingTimeInterval(2.2), silenceSeconds: 1.2)
        let first = try #require(firstOutput)
        #expect(first.samples.count == 35200)
        #expect(first.speech.lastVoiceAt == start.addingTimeInterval(1))
        #expect(!first.truncated)
        #expect(audio.pendingSpeech == nil)
        // More speech begins 3.5 seconds after the last voice, and lasts beyond that deadline.
        _ = audio.ingest(voice, isVoiced: true, endingAt: start.addingTimeInterval(4.6), silenceSeconds: 1.2)
        let session = UtteranceContinuation(text: "最初", speech: first.speech, seconds: 3.6)
        #expect(session.shouldWait(now: start.addingTimeInterval(5), pending: audio.pendingSpeech))
    }

    @Test func continuationUsesVoiceEndNotChunkEndInferenceOrSendTime() {
        var session = UtteranceContinuation(text: "最初", speech: interval(0, 1), seconds: 3.6)
        #expect(session.deadline == start.addingTimeInterval(4.6))
        #expect(!session.shouldWait(now: start.addingTimeInterval(4.6), pending: nil))
        #expect(!session.accepts(interval(4.6, 5)))
        #expect(!session.accepts(interval(5, 6)))
        // Recognition may finish much later. The start of capture determines eligibility.
        let appended1 = session.append("続き", speech: interval(4.59, 12))
        #expect(appended1)
        #expect(session.text == "最初\n続き")
        #expect(session.deadline == start.addingTimeInterval(15.6))
        let appended2 = session.append("さらに続き", speech: interval(14, 15))
        #expect(appended2)
        #expect(session.text == "最初\n続き\nさらに続き")
        #expect(session.deadline == start.addingTimeInterval(18.6))
    }

    @Test func latePendingSpeechAndEmptyOrOutOfOrderRecognitionCannotExtendSession() {
        var session = UtteranceContinuation(text: "first", speech: interval(0, 1), seconds: 3.6)
        #expect(!session.shouldWait(now: start.addingTimeInterval(8), pending: interval(4.6, 8)))
        let appended3 = session.append(" \n ", speech: interval(2.3, 3))
        #expect(!appended3)
        let appended4 = session.append("old", speech: interval(0, 0.5))
        #expect(!appended4)
        #expect(session.text == "first")
        #expect(session.lastVoiceAt == start.addingTimeInterval(1))
    }

    @Test func segmenterKeepsPreRollRejectsBriefNoiseAndCapsLongAudio() throws {
        var audio = AudioSegmenter()
        _ = audio.ingest([Float](repeating: 0, count: 16000), isVoiced: false, endingAt: start, silenceSeconds: 1.2)
        _ = audio.ingest([Float](repeating: 0.1, count: 1600), isVoiced: true, endingAt: start.addingTimeInterval(0.1), silenceSeconds: 1.2)
        let output = audio.ingest([Float](repeating: 0, count: 19200), isVoiced: false, endingAt: start.addingTimeInterval(1.3), silenceSeconds: 1.2)
        #expect(output == nil)
        #expect(audio.pendingSpeech == nil)
        let longOutput = audio.ingest([Float](repeating: 0.1, count: 400000), isVoiced: true, endingAt: start.addingTimeInterval(30), silenceSeconds: 1.2)
        let long = try #require(longOutput)
        #expect(long.truncated)
        #expect(audio.pendingSpeech == nil)
        _ = audio.ingest([Float](repeating: 0, count: 16000), isVoiced: false, endingAt: start.addingTimeInterval(31), silenceSeconds: 1.2)
        _ = audio.ingest([Float](repeating: 0.1, count: 16000), isVoiced: true, endingAt: start.addingTimeInterval(32), silenceSeconds: 1.2)
        let nextOutput = audio.ingest([Float](repeating: 0, count: 19200), isVoiced: false, endingAt: start.addingTimeInterval(33.2), silenceSeconds: 1.2)
        let next = try #require(nextOutput)
        #expect(next.samples.count == 8000 + 16000 + 19200)
        #expect(next.speech.startedAt == start.addingTimeInterval(31))
    }

    @Test func timingSettingsMigrateRoundTripAndValidateIndependently() throws {
        let old = try SettingsCodec.decode(Data(#"{"silenceSeconds":1.8}"#.utf8), systemLanguage: .japanese)
        #expect(old.silenceSeconds == 1.8 && old.continuationSeconds == 3.6)
        let longSilence = try SettingsCodec.decode(Data(#"{"silenceSeconds":4}"#.utf8), systemLanguage: .japanese)
        #expect(longSilence.silenceSeconds == 4 && longSilence.continuationSeconds > 4)
        try longSilence.validate()
        var custom = old
        custom.continuationSeconds = 5
        try custom.validate()
        #expect(try SettingsCodec.decode(JSONEncoder().encode(custom)).continuationSeconds == 5)
        for invalid in [Double.nan, .infinity, 0, 31, custom.silenceSeconds] {
            custom.continuationSeconds = invalid
            #expect(throws: (any Error).self) { try custom.validate() }
        }
    }

    @Test func aLongPausePreservesPartialAudioAndFreezesContinuationAndWakeDeadlines() throws {
        var audio = AudioSegmenter()
        _ = audio.ingest([Float](repeating: 0.1, count: 8000), isVoiced: true,
            endingAt: start.addingTimeInterval(1), silenceSeconds: 1.2)
        var continuation = UtteranceContinuation(text: "first", speech: interval(0, 0.5), seconds: 3.6)
        var wake = VoiceRouter()
        #expect(wake.accept("computer", phrases: "computer", replyPhrases: "reply", now: start, timeout: 5) == .armed(.message))
        // Several minutes of screen work do not add silence, truncate audio or expire the voice command.
        audio.shift(by: 300)
        continuation.shift(by: 300)
        wake.shift(by: 300)
        _ = audio.ingest([Float](repeating: 0.2, count: 8000), isVoiced: true,
            endingAt: start.addingTimeInterval(301.5), silenceSeconds: 1.2)
        let output = audio.ingest([Float](repeating: 0, count: 19200), isVoiced: false,
            endingAt: start.addingTimeInterval(302.7), silenceSeconds: 1.2)
        let chunk = try #require(output)
        #expect(chunk.samples.prefix(8000).allSatisfy { $0 == 0.1 })
        #expect(chunk.samples.dropFirst(8000).prefix(8000).allSatisfy { $0 == 0.2 })
        #expect(chunk.samples.count == 35200 && !chunk.truncated)
        #expect(chunk.speech == interval(300.5, 301.5))
        #expect(continuation.accepts(chunk.speech))
        let appended = continuation.append("continued", speech: chunk.speech)
        #expect(appended)
        #expect(continuation.text == "first\ncontinued")
        #expect(wake.accept("instruction", phrases: "computer", replyPhrases: "reply", now: start.addingTimeInterval(303), timeout: 5) == .command("instruction", .message))
    }
}
