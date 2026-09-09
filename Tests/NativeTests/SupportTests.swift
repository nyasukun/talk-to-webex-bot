import Testing
import Foundation
import AppKit
import RelayCore
@testable import LocalVoiceRelay

@MainActor struct SupportTests {
    @Test func tokenRecoveryOpensOnlyTheOfficialPortalOnce() {
        var urls: [URL] = []
        let model = AppModel(preview: true, openPortal: { urls.append($0); return true })
        model.handleAuthenticationFailure()
        model.handleAuthenticationFailure()
        #expect(urls == [TokenRecovery.portalURL])
        #expect(model.showTokenRenewal)
        model.showTokenRenewal = false
        model.handleAuthenticationFailure()
        #expect(urls.count == 1)
        #expect(!model.showTokenRenewal)
        model.presentTokenRenewal()
        #expect(model.showTokenRenewal)
        model.openTokenPortal()
        #expect(urls.count == 2)
    }
    @Test func healthyBackgroundCheckDoesNotDismissManualTokenEntry() {
        let model = AppModel(preview: true, openPortal: { _ in true })
        model.presentTokenRenewal()
        model.authenticationSucceeded()
        #expect(model.showTokenRenewal)
        model.authenticationSucceeded(dismissRenewal: true)
        #expect(!model.showTokenRenewal)
    }
    @Test func browserFailureRemainsRecoverableWithoutRepeatedOpen() {
        var calls = 0
        let model = AppModel(preview: true, openPortal: { _ in calls += 1; return false })
        model.handleAuthenticationFailure()
        #expect(!model.tokenBrowserOpened)
        #expect(model.showTokenRenewal)
        model.handleAuthenticationFailure()
        #expect(calls == 1)
    }
    @Test func logsBoundHistoryPersistPrivatelyAndNeverStoreErrorContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        let log = DiagnosticLog(file: file, capacity: 3)
        log.record(.launched)
        log.record(.replyProgress, category: .webex, metrics: [.polls: 15, .updates: 1, .seconds: .nan])
        log.failure(RelayError.message("synthetic-sensitive-content"))
        log.record(.speechCompleted, category: .speech)
        #expect(log.entries.count == 3)
        let contents = try String(contentsOf: file)
        #expect(!contents.contains("synthetic-sensitive-content"))
        #expect(!contents.contains("NaN"))
        #expect(!log.text(log.entries).contains("synthetic-sensitive-content"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let restored = DiagnosticLog(file: file, capacity: 3)
        #expect(restored.entries.count == 3)
        #expect(restored.entries.first?.event == .replyProgress)
        #expect(restored.entries.first?.metrics[LogMetric.updates.rawValue] == 1)
        restored.clear()
        #expect(DiagnosticLog(file: file).entries.isEmpty)
    }
    @Test func numericReadingMigrationPreservesExistingEditsAndDoesNotReinsertDeletedInstructions() throws {
        let custom = "{{transcript}}\n自分で編集した指示です。"
        let data = try JSONSerialization.data(withJSONObject: ["template": custom, "speechTemplateVersion": 1])
        var settings = try PrivateStorage.decodeSettings(data)
        #expect(settings.template == custom + "\n" + MessageTemplate.numberInstructions)
        #expect(try PrivateStorage.decodeSettings(JSONEncoder().encode(settings)).template == settings.template)
        settings.template = custom
        #expect(try PrivateStorage.decodeSettings(JSONEncoder().encode(settings)).template == custom)
        #expect(settings.replyTemplate == MessageTemplate.defaultReplyValue)
    }
    @Test func replyInstructionsMigrateOnlyTheOldDefaultAndRespectLaterEdits() throws {
        var migrated = try PrivateStorage.decodeSettings(Data(#"{"replyTemplate":"{{transcript}}"}"#.utf8))
        #expect(migrated.replyTemplate == MessageTemplate.defaultReplyValue)
        migrated.replyTemplate = "{{transcript}}"
        #expect(try PrivateStorage.decodeSettings(JSONEncoder().encode(migrated)).replyTemplate == "{{transcript}}")
        let custom = "ユーザからの追加指示：{{transcript}}"
        let data = try JSONSerialization.data(withJSONObject: ["replyTemplate": custom])
        #expect(try PrivateStorage.decodeSettings(data).replyTemplate == custom)
    }
    @Test func coloredStatusIconsAreNotTemplatesAndIdleUsesSystemAppearance() {
        #expect(StatusIcon.image(for: .idle).isTemplate)
        #expect(!StatusIcon.image(for: .receiving).isTemplate)
        #expect(!StatusIcon.image(for: .sent).isTemplate)
        #expect(StatusIcon.image(for: .receiving).tiffRepresentation != StatusIcon.image(for: .sent).tiffRepresentation)
    }
}
