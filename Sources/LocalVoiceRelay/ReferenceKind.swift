import Foundation
import RelayCore

/// Which reference recording a settings action targets: the speaker-verification sample or the voice-cloning sample.
enum ReferenceKind: String {
    case speaker, voice

    var pathKeyPath: WritableKeyPath<Settings, String> {
        switch self {
        case .speaker: return \.speakerAudioPath
        case .voice: return \.referenceAudioPath
        }
    }

    func newFileURL() -> URL { PrivateStorage.directory.appendingPathComponent("\(rawValue)-\(UUID().uuidString).wav") }
}
