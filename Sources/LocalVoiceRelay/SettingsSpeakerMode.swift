import RelayCore

extension Settings {
    /// Speaker verification is on and the command audio must match the registered speaker before sending.
    var verifiesSpeakerStrictly: Bool { speakerVerification && speakerMode == "strict" }
    /// Speaker verification is on and the registered speaker is preferred when several people talk.
    var prefersRegisteredSpeaker: Bool { speakerVerification && speakerMode == "prefer" }
}
