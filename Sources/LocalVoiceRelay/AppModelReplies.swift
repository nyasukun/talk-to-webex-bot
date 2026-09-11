// Reply polling, speech warmup and playback after a completed delivery.
import Foundation
import RelayCore

extension AppModel {
    func monitor(client: WebexClient, sent: Message, baseline: [Message], settings: Settings, run: UUID, supersededRequestIDs: Set<String> = []) async throws {
        guard supersededRequestIDs.isEmpty || sent.parentId == nil else {
            replyMonitoringStatus = L10n.text("同じスレッド内に複数の送信があり、対象の送信への返信を特定できません。Webexで返信を確認してください。")
            logs.record(.replyCorrelationUnavailable, category: .webex, level: .warning)
            return
        }
        guard let sentAt = parseDate(sent.created) else { throw RelayError.message(L10n.text("送信は完了しましたが、返信を照合する送信時刻がありません。Webexで確認してください。")) }
        if settings.waitingSound {
            do { try waitingSound.start(volume: settings.waitingSoundVolume) }
            catch {
                diagnostics = L10n.text("ソナー音を再生できません。返信監視は続けます。")
                logs.record(.sonarFailed, category: .speech, level: .warning)
            }
        }
        voiceStandbyStatus = settings.ttsEngine == "system" ? L10n.text("音声待機: Mac標準音声") : L10n.text("音声待機: 返信後に準備")
        let warmup: Task<Void, Error>? = settings.hotStandby && settings.ttsEngine == "qwen" ? Task {
            logs.record(.speechWarming, category: .speech)
            voiceStandbyStatus = L10n.text("音声待機: モデルと参照音声を準備中")
            do {
                try await speech.warmup(settings: settings, worker: worker)
                guard run == epoch, !Task.isCancelled else { return }
                logs.record(.speechReady, category: .speech)
                voiceStandbyStatus = L10n.text("音声待機: 準備完了")
            } catch {
                if run == epoch { voiceStandbyStatus = L10n.text("音声待機: 準備できませんでした") }
                throw error
            }
        } : nil
        defer {
            warmup?.cancel()
            waitingSound.stop()
        }
        var tracker = ReplyTracker(request: sent, ownPersonID: ownID, baseline: Set(baseline.map(\.id)),
                                   settleSeconds: settings.replySettleSeconds, busyPhrases: settings.busyPatterns.components(separatedBy: .newlines),
                                   requireThreaded: settings.requireThreadedReply, supersededRequestIDs: supersededRequestIDs)
        let deadline = Date().addingTimeInterval(settings.replyTimeoutSeconds)
        var polls = 0
        var failures = 0
        var lastLog = Date.distantPast, lastUpdates = -1, lastCandidates = -1, lastBusy = -1
        while Date() < deadline, run == epoch {
            try Task.checkCancellation()
            phase = .waiting
            detail = L10n.text("返信の新着と本文更新を確認しています。")
            do {
                var messages = try await client.messages(roomID: sent.roomId, since: sentAt)
                // Fetch known IDs directly even when they fall off the newest list page.
                for id in tracker.candidateIDs {
                    let current = try await client.message(id: id)
                    messages.removeAll { $0.id == id }
                    messages.append(current)
                }
                guard run == epoch else { return }
                let ready = tracker.ingest(messages, now: Date())
                polls += 1
                replyMonitoringStatus = L10n.text("取得 \(polls)回 / 返信候補 \(tracker.candidateIDs.count)件 / 途中表示 \(tracker.busyMessageCount)件 / 同一IDの本文更新 \(tracker.bodyUpdateCount)回")
                if !supersededRequestIDs.isEmpty {
                    replyMonitoringStatus += L10n.text(" / 複数の送信があるため、対象メッセージに紐づく返信だけを読み上げます。")
                }
                if Date().timeIntervalSince(lastLog) >= 5 || lastUpdates != tracker.bodyUpdateCount || lastCandidates != tracker.candidateIDs.count || lastBusy != tracker.busyMessageCount || !ready.isEmpty {
                    logs.record(.replyProgress, category: .webex, metrics: [.polls: Double(polls), .candidates: Double(tracker.candidateIDs.count), .busyMessages: Double(tracker.busyMessageCount), .updates: Double(tracker.bodyUpdateCount)])
                    lastLog = Date()
                    lastUpdates = tracker.bodyUpdateCount
                    lastCandidates = tracker.candidateIDs.count
                    lastBusy = tracker.busyMessageCount
                }
                if tracker.interruptedByOtherRequest { throw RelayError.message(L10n.text("同じDMに別の送信がありました。返信の取り違えを避けるため読み上げ監視を終了しました。")) }
                if !ready.isEmpty {
                    if let message = tracker.readyMessages.last { lastReplyTarget = ThreadReplyTarget(message: message) }
                    reply = ready.joined(separator: "\n\n")
                    phase = .speaking
                    detail = L10n.text("返信を確認しました。最初の音声を準備しています。")
                    let received = Date()
                    try await warmup?.value
                    guard run == epoch else { return }
                    try await speech.speak(reply, settings: settings, worker: worker, onSplit: { count in
                        logs.record(.speechSubdivided, category: .speech, metrics: [.count: Double(count)])
                    }, onProgress: recordSpeechProgress) {
                        waitingSound.stop()
                        logs.record(.speechStarted, category: .speech, metrics: [.seconds: Date().timeIntervalSince(received)])
                        detail = L10n.text("返信をローカル音声で読み上げています。")
                        voiceStandbyStatus += String(format: L10n.text(" / 返信確定から再生開始 %.1f秒"), Date().timeIntervalSince(received))
                    }
                    logs.record(.speechCompleted, category: .speech)
                    replyMonitoringStatus += L10n.text(" / 読み上げ完了")
                    return
                }
                failures = 0
            } catch RelayError.rateLimited(let delay) {
                logs.record(.rateLimited, category: .webex, level: .warning, metrics: [.seconds: delay])
                detail = L10n.text("API制限の解除を待っています。送信の再実行は行いません。")
                let wait = min(delay, max(0, deadline.timeIntervalSinceNow))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch let error as URLError {
                logs.failure(error, category: .webex)
                failures += 1
                guard failures < 4 else { throw error }
                detail = L10n.text("接続を再確認しています（返信の取得のみ）。")
                try await Task.sleep(nanoseconds: UInt64(min(30, pow(2, Double(failures))) * 1_000_000_000))
            }
            try await Task.sleep(nanoseconds: UInt64(settings.replyPollSeconds * 1_000_000_000))
        }
        if run == epoch {
            logs.record(.replyTimeout, category: .webex, level: .warning)
            replyMonitoringStatus += L10n.text(" / 返信待ち終了（送信済み・再送なし・待受へ復帰）")
        }
    }
}
