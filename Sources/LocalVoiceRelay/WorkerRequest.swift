import RelayCore

/// Builds the JSON payloads sent to worker/relay_worker.py. Pure functions: callers still pass `python: settings.pythonPath` to LocalWorker.call.
enum WorkerRequest {
    static func diagnose(settings: Settings) -> [String: Any] {
        ["action": "diagnose", "model": settings.asrModelPath,
         "voice_model": settings.ttsEngine == "qwen" ? settings.ttsModelPath : ""]
    }
    /// The listening path passes `verifyInline: false` and verifies the command chunk separately via `verifySpeaker` after wake detection;
    /// the microphone test passes `true` so the worker checks the recording in the same call.
    static func transcribe(audio: String, settings: Settings, verifyInline: Bool) -> [String: Any] {
        var request: [String: Any] = ["action": "transcribe", "audio": audio, "model": settings.asrModelPath,
                                      "prefer_speaker": settings.prefersRegisteredSpeaker,
                                      "reference_audio": settings.speakerAudioPath]
        if verifyInline {
            request["verify_speaker"] = settings.verifiesSpeakerStrictly
            request["speaker_threshold"] = settings.speakerThreshold
        }
        return request
    }
    static func verifySpeaker(audio: String, settings: Settings) -> [String: Any] {
        ["action": "verify_speaker", "audio": audio,
         "reference_audio": settings.speakerAudioPath,
         "speaker_threshold": settings.speakerThreshold]
    }
    static func warmSpeech(settings: Settings) -> [String: Any] {
        ["action": "warm_speech", "model": settings.ttsModelPath,
         "reference_audio": settings.referenceAudioPath,
         "reference_text": settings.referenceText,
         "reduce_reference_noise": settings.reduceReferenceNoise]
    }
    static func beginSpeech(text: String, settings: Settings) -> [String: Any] {
        var request = warmSpeech(settings: settings)
        request["action"] = "begin_speech"
        request["text"] = text
        return request
    }
    static func nextSpeech(output: String) -> [String: Any] {
        ["action": "next_speech", "output": output]
    }
}
