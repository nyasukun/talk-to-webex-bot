import Foundation
import Combine
import RelayCore

enum LogLevel: String, Codable, CaseIterable { case info = "情報", warning = "注意", error = "エラー" }
enum LogCategory: String, Codable, CaseIterable { case app = "アプリ", audio = "音声入力", webex = "Webex", speech = "読み上げ", permissions = "権限" }
enum LogEvent: String, Codable {
    case launched, settingsSaved, stopped, microphoneStarted, microphoneTest, recognitionAccepted, recognitionRejected
    case wakeDetected, speakerMeasured, screenCaptured, permissionsChecked, environmentReady
    case tokenValid, tokenExpired, tokenAccessRequired, tokenSaved, browserOpened, browserFailed, roomsLoaded
    case sendStarted, sendCompleted, sendAmbiguous, replyProgress, replyTimeout, rateLimited, networkFailure
    case speechWarming, speechReady, speechStarted, speechCompleted, sonarFailed, operationFailed
    case inputInterrupted, inputRecovered, inputRecoveryFailed, microphoneSampled
    case utteranceDiscarded, inputBacklogDiscarded, commandWaitExpired
    case screenOmitted, speechSubdivided, speechLineReady, speechBufferWait
    var message: String {
        switch self {
        case .launched: return "アプリを起動しました"
        case .settingsSaved: return "設定を保存しました"
        case .stopped: return "停止してマイクと音声モデルを解放しました"
        case .microphoneStarted: return "マイク入力を開始しました"
        case .microphoneTest: return "送信しないマイクテストを完了しました"
        case .microphoneSampled: return "マイクテストの録音を終了しました"
        case .recognitionAccepted: return "音声を認識しました"
        case .recognitionRejected: return "認識の信頼度または音声区間が不足しています"
        case .wakeDetected: return "合言葉を検出しました"
        case .speakerMeasured: return "話者類似度を計測しました"
        case .screenCaptured: return "前面ウィンドウの画像とOCRを取得しました"
        case .screenOmitted: return "対象画面を取得できないため、画像とOCRを省いて音声の指示だけで続行します"
        case .permissionsChecked: return "必要な権限を確認しました"
        case .environmentReady: return "ローカル音声環境の診断が完了しました"
        case .tokenValid: return "Webex認証は有効です"
        case .tokenExpired: return "Webex認証が無効です。更新を案内しました"
        case .tokenAccessRequired: return "保存済みトークンを読み込めませんでした。Webex設定を確認してください"
        case .tokenSaved: return "新しいトークンを検証し、キーチェーンに保存しました"
        case .browserOpened: return "既定のブラウザでトークン取得ページを開きました"
        case .browserFailed: return "取得ページを開けませんでした。認証画面から再度開いてください"
        case .roomsLoaded: return "最近のDMを取得しました"
        case .sendStarted: return "Webexへの送信処理を開始しました"
        case .sendCompleted: return "Webexへの送信が完了しました"
        case .sendAmbiguous: return "送信結果が不明です。再送せずWebexで確認してください"
        case .replyProgress: return "返信の新着と同一IDの更新を確認しました"
        case .replyTimeout: return "返信待ちを終了し、次の合言葉の待受へ戻ります。送信は繰り返しません"
        case .utteranceDiscarded: return "25秒に達した音声区間を破棄しました。常時待受は継続します"
        case .inputBacklogDiscarded: return "処理が追いつかない音声を破棄しました。常時待受は継続します"
        case .commandWaitExpired: return "指示の受付を区切りました。次の合言葉を待ちます"
        case .rateLimited: return "API制限の解除を待ちます"
        case .networkFailure: return "通信に失敗しました"
        case .speechWarming: return "音声モデルと参照音声を準備しています"
        case .speechReady: return "音声モデルの準備が完了しました"
        case .speechStarted: return "読み上げの再生を開始しました"
        case .speechCompleted: return "読み上げが完了しました"
        case .speechSubdivided: return "未再生の長い音声区間をさらに分割して生成しました"
        case .speechLineReady: return "次の行の音声を生成して再生待ちに追加しました"
        case .speechBufferWait: return "先行音声が尽きたため次の行の生成を待ちました"
        case .sonarFailed: return "ソナー音を再生できませんでした"
        case .operationFailed: return "処理に失敗しました。ホームの案内を確認してください"
        case .inputInterrupted: return "入力デバイスの変更または音声フレームの途絶を検出しました"
        case .inputRecovered: return "マイクを再接続しました。途中の発話は破棄しました"
        case .inputRecoveryFailed: return "マイクの再接続が続けて失敗しました。入力デバイスを確認してください"
        }
    }
}
enum LogMetric: String, Codable, CaseIterable {
    case seconds = "秒", count = "件数", polls = "取得回数", candidates = "返信候補", busyMessages = "途中表示", updates = "本文更新"
    case similarity = "話者類似度", overall = "発話全体", threshold = "しきい値", window = "区間", level = "入力最大", networkCode = "通信エラー番号"
    case sampleRate = "入力Hz", channels = "入力チャンネル数"
    case keychainStatus = "キーチェーン状態"
    case microphone = "マイク許可", screen = "画面収録許可", screenEnabled = "スクショ有効"
    case speechLine = "行", speechLines = "総行数", generationSeconds = "生成秒", audioSeconds = "音声秒", bufferedSeconds = "再生残秒"
}
struct LogEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let category: LogCategory
    let level: LogLevel
    let event: LogEvent
    let metrics: [String: Double]
    var details: String { metrics.sorted { $0.key < $1.key }.map { "\($0.key): \(String(format: "%.3g", $0.value))" }.joined(separator: "  ·  ") }
}

/// Persist only known events and numeric measurements; no free text, payloads, paths or credentials.
@MainActor final class DiagnosticLog: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var storageFailed = false
    private let file: URL?
    private let capacity: Int
    init(file: URL? = nil, capacity: Int = 500) {
        self.file = file; self.capacity = max(1, capacity)
        if let file, let data = try? PrivateFiles.read(file, maximumBytes: 1_000_000),
           let saved = try? JSONDecoder().decode([LogEntry].self, from: data) {
            let allowed = Set(LogMetric.allCases.map(\.rawValue))
            entries = saved.suffix(self.capacity).map {
                LogEntry(id: $0.id, date: $0.date, category: $0.category, level: $0.level, event: $0.event,
                         metrics: $0.metrics.filter { allowed.contains($0.key) && $0.value.isFinite })
            }
        }
    }
    func record(_ event: LogEvent, category: LogCategory = .app, level: LogLevel = .info, metrics: [LogMetric: Double] = [:]) {
        entries.append(LogEntry(id: UUID(), date: Date(), category: category, level: level, event: event,
                                metrics: Dictionary(uniqueKeysWithValues: metrics.filter { $0.value.isFinite }.map { ($0.key.rawValue, $0.value) })))
        entries = Array(entries.suffix(capacity))
        persist()
    }
    func failure(_ error: Error, category: LogCategory = .app) {
        switch error {
        case RelayError.unauthorized: record(.tokenExpired, category: .webex, level: .error)
        case RelayError.ambiguousSend: record(.sendAmbiguous, category: .webex, level: .error)
        case RelayError.rateLimited(let delay): record(.rateLimited, category: .webex, level: .warning, metrics: [.seconds: delay])
        case let error as TokenReadError: record(.tokenAccessRequired, category: .webex, level: .warning, metrics: [.keychainStatus: Double(error.status)])
        case let error as URLError: record(.networkFailure, category: .webex, level: .error, metrics: [.networkCode: Double(error.code.rawValue)])
        case is CancellationError: break
        default: record(.operationFailed, category: category, level: .error)
        }
    }
    func clear() { entries = []; persist() }
    func text(_ entries: [LogEntry]) -> String {
        entries.map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] [\($0.category.rawValue)] \($0.event.message) \($0.details)" }.joined(separator: "\n")
    }
    private func persist() {
        guard let file else { return }
        do {
            try PrivateFiles.write(JSONEncoder().encode(entries), to: file)
            storageFailed = false
        } catch { storageFailed = true }
    }
}
