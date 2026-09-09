// Reference audio recording and import for AppModel.
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import RelayCore

extension AppModel {
    private func persistReference(kind: ReferenceKind, path: String) throws {
        var saved = savedSettings
        saved[keyPath: kind.pathKeyPath] = path
        try PrivateStorage.save(saved)
        settings[keyPath: kind.pathKeyPath] = path
        savedSettings = saved
        logs.record(.settingsSaved)
    }
    func chooseReference(kind: ReferenceKind) {
        guard canConfigure else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .aiff, .mpeg4Audio, .mp3]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try PrivateStorage.prepare()
            let target = kind.newFileURL()
            do { try AudioRecorder.importReference(from: source, to: target) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            do { try persistReference(kind: kind, path: target.path) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            detail = "参照音声をこのMacのアプリ用フォルダへコピーしました。他の設定は「変更を保存」で適用します。"
        } catch { fail(error) }
    }
    func startReference(kind: ReferenceKind) async {
        guard canConfigure else { return }
        stop(); let run = epoch
        phase = .preparing; detail = "許可済みのマイクで参照音声を録音します。"
        do {
            try Permissions.requireMicrophone()
            guard run == epoch else { return }
            try PrivateStorage.prepare()
            let url = kind.newFileURL()
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000,
                                                                     AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard recorder.record(forDuration: 30) else { throw RelayError.message("参照音声の録音を開始できません。") }
            referenceRecorder = recorder; referenceKind = kind; referenceURL = url; referenceRecording = true
            phase = .recording
            detail = "参照音声を録音中です。10〜20秒話し、録音終了を押してください（最大30秒）。"
            launch { [self] _ in try? await Task.sleep(nanoseconds: 30_000_000_000); if !Task.isCancelled { finishReference() } }
        } catch { if run == epoch { fail(error) } }
    }
    func finishReference() {
        guard referenceRecording, let recorder = referenceRecorder, let url = referenceURL else { return }
        recorder.stop(); operation?.cancel(); referenceRecorder = nil; referenceRecording = false
        phase = .stopped
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let audioFile = try AVAudioFile(forReading: url)
            guard Double(audioFile.length) / audioFile.processingFormat.sampleRate >= 3 else {
                try? FileManager.default.removeItem(at: url)
                throw RelayError.message("録音が3秒未満です。10〜20秒の参照音声を録り直してください。")
            }
            try persistReference(kind: referenceKind, path: url.path)
            detail = "参照音声を保存しました。これは追加学習ではありません。声の再現用には読んだ本文も入力してください。"
        } catch { fail(error) }
    }
}
