import Foundation

/// The model generates sequentially while the audio engine plays independently.
@MainActor enum SpeechPipeline {
    static let maximumBufferedLines = 2
    static let maximumBufferedSeconds = 30.0

    static func run<Line>(next: () async throws -> Line?, enqueue: (Line) throws -> Void,
                          start: () -> Void, waitForCapacity: () async throws -> Void,
                          finish: () async throws -> Void, stop: () -> Void) async throws {
        defer { stop() }
        var started = false
        while true {
            try Task.checkCancellation()
            if started {
                try await waitForCapacity()
                try Task.checkCancellation()
            }
            let line = try await next()
            try Task.checkCancellation()
            guard let line else { break }
            try enqueue(line)
            if !started {
                start(); started = true
            }
        }
        if started { try await finish() }
    }
}

struct SpeechLineProgress {
    let line: Int
    let total: Int
    let generationSeconds: Double
    let audioSeconds: Double
    let bufferedSeconds: Double
    let bufferRanOut: Bool
}

struct PlaybackProgress {
    private var remainingSeconds: Double
    private var lastProgress: ContinuousClock.Instant

    init(remainingSeconds: Double, now: ContinuousClock.Instant = .now) {
        self.remainingSeconds = remainingSeconds; self.lastProgress = now
    }
    mutating func stalled(remainingSeconds: Double, now: ContinuousClock.Instant = .now) -> Bool {
        if remainingSeconds < self.remainingSeconds {
            self.remainingSeconds = remainingSeconds; lastProgress = now
        }
        return now >= lastProgress.advanced(by: .seconds(30))
    }
}
