import Foundation
import RelayCore

extension AppModel {
    var statusTitle: String {
        if listening, [.listening, .recording, .recognizing].contains(phase) {
            if acceptingContinuation { return L10n.text("続きの発話を受け付けています") }
            return indicator == .receiving ? L10n.text("指示を受け付けています") : L10n.text("合言葉を待っています")
        }
        return phase.title
    }
    enum SetupStep { case permissions, token, destination, models }
    var nextSetupStep: SetupStep? {
        if !permissionsReady { return .permissions }
        if !tokenValid { return .token }
        if settings.roomID.isEmpty { return .destination }
        if !FileManager.default.isExecutableFile(atPath: settings.pythonPath) || !FileManager.default.fileExists(atPath: settings.asrModelPath) { return .models }
        return nil
    }
    var filteredRooms: [Room] { Room.filtered(rooms, query: query) }
    var canConfigure: Bool { !listening && !referenceRecording && !busy && [.stopped, .error].contains(phase) }
    var permissionsReady: Bool { permissionSnapshot.missing(includeScreen: settings.includeScreen).isEmpty }
    var tokenEstimate: String {
        switch TokenHealth.estimate(issuedAt: settings.tokenIssuedAt, now: Date()) {
        case .unknown: return L10n.text("発行時刻不明。保存時刻から期限を推測せず、5分ごとにAPIで確認します。")
        case .valid: return L10n.text("入力された発行時刻では有効期間内です。APIで別途確認します。")
        case .expiring: return L10n.text("入力された発行時刻から、期限まで30分以内です。更新してください。")
        case .expired: return L10n.text("入力された発行時刻から12時間を過ぎています。更新してください。")
        }
    }
}
