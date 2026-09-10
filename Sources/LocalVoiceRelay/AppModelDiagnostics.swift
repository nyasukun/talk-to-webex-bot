// Local environment, speech, microphone and speaker diagnostics for AppModel.
import Foundation
import RelayCore

extension AppModel {
    func checkLocal() async {
        guard canConfigure else { return }
        let run = epoch
        busy = true
        defer { busy = false }
        do {
            let result = try await worker.call(WorkerRequest.diagnose(settings: settings), python: settings.pythonPath)
            guard run == epoch else { return }
            diagnostics = result["summary"] as? String ?? "ローカル環境を確認しました。"
            detail = diagnostics
            logs.record(.environmentReady)
        } catch {
            if run == epoch {
                diagnostics = error.localizedDescription
                fail(error)
            }
        }
    }
    func prepareTextTest() {
        guard canConfigure else { return }
        stop()
        launch { [self] run in
            try validateDestination()
            transcript = testInput
            try await prepare(command: testInput, run: run, forceConfirmation: true)
        }
    }
    func testSpeech() {
        guard canConfigure else { return }
        stop()
        phase = .speaking
        launch { [self] run in
            guard !speechTestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  speechTestText.count <= 20000 else { throw RelayError.message("試聴する文章は1〜20,000文字で入力してください。") }
            try await speech.speak(speechTestText, settings: settings, worker: worker, onSplit: { count in
                self.logs.record(.speechSubdivided, category: .speech, metrics: [.count: Double(count)])
            }, onProgress: recordSpeechProgress) { self.logs.record(.speechStarted, category: .speech) }
            logs.record(.speechCompleted, category: .speech)
            guard run == epoch else { return }
            phase = .stopped
            detail = "読み上げが終わりました。発音と声質を確認してください。"
        }
    }
    func recordSpeechProgress(_ progress: SpeechLineProgress) {
        let metrics: [LogMetric: Double] = [.speechLine: Double(progress.line), .speechLines: Double(progress.total),
                                          .generationSeconds: progress.generationSeconds, .audioSeconds: progress.audioSeconds,
                                          .bufferedSeconds: progress.bufferedSeconds]
        logs.record(.speechLineReady, category: .speech, metrics: metrics)
        if progress.bufferRanOut { logs.record(.speechBufferWait, category: .speech, level: .warning, metrics: metrics) }
    }
    func testMicrophone() {
        guard canConfigure else { return }
        stop()
        phase = .preparing
        detail = "許可済みのマイクをテストします。Webexへは送信しません。"
        launch { [self] run in
            defer { if run == epoch { microphoneTestProgress = nil } }
            try Permissions.requireMicrophone()
            guard run == epoch else { return }
            let file = try PrivateStorage.temporaryFile(extension: "wav")
            defer { try? FileManager.default.removeItem(at: file) }
            var peak = Float(0)
            recorder.onChunk = nil
            recorder.onConfigurationChange = { [weak self] in Task { @MainActor in
                guard let self, run == self.epoch else { return }
                self.logs.record(.inputInterrupted, category: .audio, level: .warning)
                self.fail(RelayError.message("テスト中にマイクの音声形式が変わりました。入力デバイスが安定してから、もう一度テストしてください。"))
            } }
            recorder.onError = { [weak self] message in Task { @MainActor in
                guard let self, self.epoch == run else { return }
                self.fail(RelayError.message(message))
            } }
            recorder.onLevel = { [weak self] value in Task { @MainActor in
                guard let self, self.epoch == run, self.phase == .recording else { return }
                self.level = value
                peak = max(peak, value)
            } }
            try await recorder.start(silenceSeconds: settings.silenceSeconds, minimumRMS: settings.minimumRMS,
                                     voiceProcessing: settings.voiceProcessing, diagnostic: true)
            phase = .recording
            detail = "5秒間のテスト録音中です。合言葉と短い指示を話してください。送信はしません。"
            microphoneTestProgress = 0
            for step in 0..<50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                microphoneTestProgress = Double(step + 1) / 50
            }
            let samples = recorder.finishDiagnostic()
            level = 0
            guard run == epoch else { return }
            logs.record(.microphoneSampled, category: .audio, metrics: [.seconds: Double(samples.count) / 16000,
                .level: Double(peak), .sampleRate: recorder.inputFormat.rate, .channels: recorder.inputFormat.channels])
            guard !samples.isEmpty else {
                throw RelayError.message("マイクから音声フレームが届きませんでした。macOSのサウンド設定と会議アプリの入力デバイスを確認し、待受を停止してから再テストしてください。")
            }
            guard peak > 0 else {
                throw RelayError.message("音声フレームは届いていますが、入力音量がゼロです。macOSのサウンド設定で内蔵マイクの入力音量を確認してください。")
            }
            try AudioRecorder.write(samples, to: file)
            phase = .recognizing
            audioStatus = String(format: "5秒録音の入力レベル最大: %.0f%%（待受と同じ録音経路）", peak * 100)
            let result = try await worker.call(WorkerRequest.transcribe(audio: file.path, settings: settings, verifyInline: true), python: settings.pythonPath)
            guard run == epoch else { return }
            updateSpeakerDiagnostics(result)
            recognizedInput = result["text"] as? String ?? ""
            let match = WakeMatcher.command(in: recognizedInput, phrases: settings.wakePhrases) != nil || WakeMatcher.command(in: recognizedInput, phrases: settings.replyWakePhrases) != nil
            logs.record(.microphoneTest, category: .audio, metrics: [.level: Double(peak), .count: match ? 1 : 0])
            phase = .stopped
            detail = recognizedInput.isEmpty ? (result["rejected"] as? String ?? "認識できませんでした。入力デバイスと音量を確認してください。") :
                (match ? "マイク・文字起こし・合言葉の一致を確認しました。送信していません。" : "文字起こしは成功しましたが、合言葉が一致しません。表示された表記を別候補として登録できます。")
        }
    }
    func updateSpeakerDiagnostics(_ result: [String: Any]) {
        let parsed = SpeakerDiagnostics(result: result)
        if let similarity = parsed.similarity {
            logs.record(.speakerMeasured, category: .audio, metrics: [.similarity: similarity, .overall: parsed.overall ?? similarity, .threshold: settings.speakerThreshold])
            for window in parsed.windows {
                logs.record(.speakerMeasured, category: .audio, metrics: [.window: Double(window.index + 1), .seconds: window.seconds, .similarity: window.similarity])
            }
        }
        // The diagnostics text intentionally follows speakerMode regardless of the speakerVerification toggle.
        diagnostics = parsed.summary(mode: settings.speakerMode, threshold: settings.speakerThreshold)
    }
}
