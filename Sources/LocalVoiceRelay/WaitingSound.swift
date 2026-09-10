import AVFoundation
import RelayCore

@MainActor final class WaitingSound {
    private var player: AVAudioPlayer?

    // A quiet, decaying ping followed by silence. Entirely generated on this Mac.
    nonisolated static func wave() -> Data {
        let rate = 24000, count = rate * 3
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        word(UInt32(36 + count * 2))
        data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16))
        word(UInt16(1))
        word(UInt16(1))
        word(UInt32(rate))
        word(UInt32(rate * 2))
        word(UInt16(2))
        word(UInt16(16))
        data.append(Data("data".utf8))
        word(UInt32(count * 2))
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            let envelope = t < 0.45 ? min(1, t / 0.015) * exp(-t * 10) * min(1, (0.45 - t) / 0.03) : 0
            word(Int16(sin(2 * .pi * (720 * t - 100 * t * t)) * envelope * 16000))
        }
        return data
    }
    func start(volume: Double) throws {
        stop()
        let player = try AVAudioPlayer(data: Self.wave())
        player.volume = Float(max(0, min(1, volume)))
        player.numberOfLoops = -1
        guard player.play() else { throw RelayError.message(L10n.text("返信待ちのソナー音を再生できません。")) }
        self.player = player
    }
    func stop() {
        player?.stop()
        player = nil
    }
}
