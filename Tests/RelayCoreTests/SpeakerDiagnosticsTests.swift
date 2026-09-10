import Testing
import Foundation
@testable import RelayCore

final class SpeakerDiagnosticsTests {
    private func window(_ seconds: Double, _ similarity: Double) -> [String: Any] { ["seconds": seconds, "similarity": similarity] }
    private func strict(_ similarity: Double, _ threshold: Double) -> String { String(format: "話者類似度 %.3f（しきい値 %.3f）", similarity, threshold) }

    @Test func absentSimilarityReturnsOnlyTheNote() {
        let bare = SpeakerDiagnostics(result: [:])
        #expect(bare.similarity == nil && bare.overall == nil && bare.rawWindows == nil && bare.windows.isEmpty)
        #expect(bare.summary(mode: "strict", threshold: 0.5, language: .japanese) == "")
        #expect(bare.summary(mode: "prefer", threshold: 0.5, language: .japanese) == "")
        let noted = SpeakerDiagnostics(result: ["speaker_note": "登録音声がありません", "overall_similarity": 0.9, "speaker_windows": [window(1, 0.5)]])
        #expect(noted.summary(mode: "strict", threshold: 0.5, language: .japanese) == "登録音声がありません")
        #expect(noted.summary(mode: "prefer", threshold: 0.5, language: .japanese) == "登録音声がありません")
    }
    @Test func preferModeAppendsAReferenceLineToTheNote() {
        let reference = String(format: "\n話者類似度 %.3f（参考値・単独発話を拒否するしきい値ではありません）", 0.4321)
        #expect(SpeakerDiagnostics(result: ["similarity": 0.4321]).summary(mode: "prefer", threshold: 0.5, language: .japanese) == reference)
        #expect(SpeakerDiagnostics(result: ["similarity": 0.4321]).summary(mode: "prefer", threshold: 0.5, language: .japanese).hasPrefix("\n"))
        let noted = SpeakerDiagnostics(result: ["similarity": 0.4321, "speaker_note": "注記", "overall_similarity": 0.9, "speaker_windows": [window(1, 0.5)]])
        #expect(noted.summary(mode: "prefer", threshold: 0.5, language: .japanese) == "注記" + reference)
    }
    @Test func strictModeIncludesOverallAndWindows() {
        let parsed = SpeakerDiagnostics(result: ["similarity": 0.61, "overall_similarity": 0.72, "speaker_windows": [window(1.5, 0.55), window(3.25, 0.66)]])
        #expect(parsed.overall == 0.72)
        let expected = strict(0.61, 0.5) + String(format: " / 発話全体 %.3f", 0.72) + "\n区間別: " +
            [String(format: "%.2f秒: %.3f", 1.5, 0.55), String(format: "%.2f秒: %.3f", 3.25, 0.66)].joined(separator: "、")
        #expect(parsed.summary(mode: "strict", threshold: 0.5, language: .japanese) == expected)
    }
    @Test func strictModeOmitsOverallWhenAbsent() {
        let text = SpeakerDiagnostics(result: ["similarity": 0.61, "speaker_windows": [window(1.5, 0.55)]]).summary(mode: "strict", threshold: 0.5, language: .japanese)
        #expect(text == strict(0.61, 0.5) + "\n区間別: " + String(format: "%.2f秒: %.3f", 1.5, 0.55))
        #expect(!text.contains("発話全体"))
    }
    @Test func windowSuffixDistinguishesAbsentEmptyAndMixedEntries() {
        let absent = SpeakerDiagnostics(result: ["similarity": 0.61])
        #expect(absent.rawWindows == nil)
        #expect(absent.summary(mode: "strict", threshold: 0.5, language: .japanese) == strict(0.61, 0.5))
        let empty = SpeakerDiagnostics(result: ["similarity": 0.61, "speaker_windows": [[String: Any]]()])
        #expect(empty.rawWindows?.isEmpty == true && empty.windows.isEmpty)
        #expect(empty.summary(mode: "strict", threshold: 0.5, language: .japanese) == strict(0.61, 0.5) + "\n区間別: ")
        let mixed = SpeakerDiagnostics(result: ["similarity": 0.61, "speaker_windows": [window(1, 0.5), ["seconds": "2", "similarity": 0.6], ["seconds": 3.0], window(4, 0.7)]])
        #expect(mixed.windows.map(\.index) == [0, 3])
        #expect(mixed.windows.map(\.seconds) == [1, 4])
        #expect(mixed.windows.map(\.similarity) == [0.5, 0.7])
        #expect(mixed.summary(mode: "strict", threshold: 0.5, language: .japanese) == strict(0.61, 0.5) + "\n区間別: " +
            [String(format: "%.2f秒: %.3f", 1.0, 0.5), String(format: "%.2f秒: %.3f", 4.0, 0.7)].joined(separator: "、"))
    }
    @Test func anyModeOtherThanPreferUsesTheStrictText() {
        let parsed = SpeakerDiagnostics(result: ["similarity": 0.61, "speaker_note": "注記"])
        for mode in ["strict", "", "PREFER", "prefer ", "unknown"] {
            #expect(parsed.summary(mode: mode, threshold: 0.25, language: .japanese) == strict(0.61, 0.25))
        }
    }
    @Test func nonNumericOverallIsIgnored() {
        let parsed = SpeakerDiagnostics(result: ["similarity": 0.61, "overall_similarity": "0.9"])
        #expect(parsed.similarity == 0.61 && parsed.overall == nil)
        #expect(parsed.summary(mode: "strict", threshold: 0.5, language: .japanese) == strict(0.61, 0.5))
    }
}
