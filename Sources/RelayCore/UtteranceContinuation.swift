import Foundation

/// Uses capture times, so inference and network latency cannot change which speech belongs together.
public struct SpeechInterval: Sendable, Equatable {
    public let startedAt: Date
    public let lastVoiceAt: Date
    public init(startedAt: Date, lastVoiceAt: Date) {
        self.startedAt = startedAt
        self.lastVoiceAt = lastVoiceAt
    }
}

public struct UtteranceContinuation {
    public private(set) var text: String
    public private(set) var lastVoiceAt: Date
    public let seconds: TimeInterval
    public var deadline: Date { lastVoiceAt.addingTimeInterval(seconds) }

    public init(text: String, speech: SpeechInterval, seconds: TimeInterval) {
        self.text = text
        lastVoiceAt = speech.lastVoiceAt
        self.seconds = seconds
    }
    public func accepts(_ speech: SpeechInterval) -> Bool {
        speech.startedAt >= lastVoiceAt && speech.startedAt < deadline
    }
    public func shouldWait(now: Date, pending: SpeechInterval?) -> Bool {
        now < deadline || pending.map(accepts) == true
    }
    @discardableResult public mutating func append(_ text: String, speech: SpeechInterval) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(speech), !text.isEmpty else { return false }
        self.text += "\n" + text
        lastVoiceAt = speech.lastVoiceAt
        return true
    }
}

/// Audio segmentation is independent of recognition, sending, and reply playback.
public struct AudioSegmenter {
    public struct Chunk: Sendable {
        public let samples: [Float]
        public let truncated: Bool
        public let speech: SpeechInterval
        public init(samples: [Float], truncated: Bool, speech: SpeechInterval = .init(startedAt: .distantPast, lastVoiceAt: .distantPast)) {
            self.samples = samples
            self.truncated = truncated
            self.speech = speech
        }
    }
    private var samples: [Float] = [], preRoll: [Float] = []
    private var silence = 0, voiced = 0
    public private(set) var pendingSpeech: SpeechInterval?
    public init() {}

    public mutating func ingest(_ floats: [Float], isVoiced: Bool, endingAt: Date, silenceSeconds: Double) -> Chunk? {
        guard !floats.isEmpty else { return nil }
        if samples.isEmpty {
            guard isVoiced else {
                preRoll += floats
                preRoll = Array(preRoll.suffix(8000))
                return nil
            }
            samples = preRoll
            pendingSpeech = SpeechInterval(startedAt: endingAt.addingTimeInterval(-Double(floats.count) / 16000), lastVoiceAt: endingAt)
        }
        samples += floats
        if isVoiced {
            silence = 0
            voiced += floats.count
            pendingSpeech = SpeechInterval(startedAt: pendingSpeech!.startedAt, lastVoiceAt: endingAt)
        } else { silence += floats.count }
        let truncated = samples.count >= 25 * 16000
        guard silence >= Int(silenceSeconds * 16000) || truncated else { return nil }
        let chunk = voiced >= 4000 ? Chunk(samples: samples, truncated: truncated, speech: pendingSpeech!) : nil
        self = AudioSegmenter()
        return chunk
    }
}
