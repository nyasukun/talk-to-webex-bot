import Testing
import AppKit
import RelayCore
@testable import LocalVoiceRelay

@MainActor struct StandbyTests {
    @Test func longAudioAndBacklogDoNotStopTheListeningSession() {
        let model = AppModel(preview: true)
        model.listening = true; model.phase = .recognizing; model.indicator = .receiving
        for _ in 0..<8 { model.acceptAudioChunk(.init(samples: [], truncated: true)) }
        #expect(model.listening)
        #expect(model.phase == .listening)
        #expect(model.indicator == .idle)
        #expect(model.draft == nil)
        #expect(model.logs.entries.filter { $0.event == .utteranceDiscarded }.count == 8)
        // Stay on the main actor so the fake queued audio cannot start inference before stop().
        for _ in 0..<4 { model.acceptAudioChunk(.init(samples: [], truncated: false)) }
        #expect(model.listening)
        #expect(model.phase == .listening)
        #expect(model.logs.entries.last?.event == .inputBacklogDiscarded)
        model.stop()
        #expect(!model.listening)
    }
    @Test func audioCannotReplaceConfirmationOrPlayback() {
        let model = AppModel(preview: true)
        model.listening = true
        for phase in [AppModel.Phase.confirming, .sending, .waiting, .speaking] {
            model.phase = phase
            model.acceptAudioChunk(.init(samples: [], truncated: true))
            #expect(model.phase == phase)
        }
        #expect(model.logs.entries.isEmpty)
        model.stop()
    }
    @Test func powerActivityEndsOnStopAndAllowsDisplaySleep() {
        var options: [ProcessInfo.ActivityOptions] = []
        var ends = 0
        let activity = StandbyActivity(begin: { options.append($0); return NSObject() }, end: { _ in ends += 1 })
        activity.update(listening: false, preventSleep: true)
        #expect(options.isEmpty)
        activity.update(listening: true, preventSleep: true)
        activity.update(listening: true, preventSleep: true)
        #expect(options.count == 1)
        #expect(options[0].contains(.idleSystemSleepDisabled))
        #expect(!options[0].contains(.idleDisplaySleepDisabled))
        activity.update(listening: true, preventSleep: false)
        #expect(ends == 1)
        #expect(!options[1].contains(.idleSystemSleepDisabled))
        activity.update(listening: false, preventSleep: false)
        activity.update(listening: false, preventSleep: false)
        #expect(ends == 2)
    }
    @Test func lockedOrUnknownSessionsCannotSupplyScreenshots() {
        let active: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
        #expect(ScreenContext.sessionAllowsCapture(active))
        #expect(!ScreenContext.sessionAllowsCapture(nil))
        #expect(!ScreenContext.sessionAllowsCapture([:]))
        #expect(!ScreenContext.sessionAllowsCapture(active.merging(["CGSSessionScreenIsLocked": true]) { _, v in v }))
        #expect(!ScreenContext.sessionAllowsCapture(active.merging([kCGSessionOnConsoleKey as String: false]) { _, v in v }))
    }
    @Test func optionalScreenSkipsCaptureWhenDisabledAndOmitsUnavailableImages() async throws {
        var calls = 0
        let absent = try await ScreenAttachment.captureIfAvailable(enabled: false) { calls += 1; throw ScreenContext.Unavailable.noWindow }
        #expect(absent == nil)
        #expect(calls == 0)
        for error in [ScreenContext.Unavailable.noWindow, .changedWindow, .inactiveSession] {
            let screen = try await ScreenAttachment.captureIfAvailable(enabled: true) { throw error }
            #expect(screen == nil)
            let body = try MessageTemplate.render(MessageTemplate.defaultValue, transcript: "接続確認です。", ocr: screen?.ocr, screen: screen != nil)
            #expect(!body.contains("OCR"))
            #expect(!body.contains("スクリーンショット"))
            #expect(body.contains("接続確認です。"))
        }
        let captured = try await ScreenAttachment.captureIfAvailable(enabled: true) { ScreenContext(png: Data([1]), ocr: "一般的な文") }
        #expect(captured?.png == Data([1]))
    }
    @Test func screenCancellationAndMissingPermissionRemainActionable() async {
        do {
            _ = try await ScreenAttachment.captureIfAvailable(enabled: true) { throw CancellationError() }
            Issue.record("Cancellation was swallowed")
        } catch { #expect(error is CancellationError) }
        do {
            _ = try await ScreenAttachment.captureIfAvailable(enabled: true) { throw RelayError.missingPermissions(["画面収録"]) }
            Issue.record("Permission error was swallowed")
        } catch {
            guard case RelayError.missingPermissions(let names) = error else { Issue.record("Wrong error"); return }
            #expect(names == ["画面収録"])
        }
    }
    @Test func destinationChangesRemainDraftsAndSetupHasOneNextStep() {
        let model = AppModel(preview: true)
        #expect(model.nextSetupStep == .token)
        model.authenticationSucceeded()
        #expect(model.nextSetupStep == .destination)
        model.selectRoom(Room(id: "room", title: "サンプルDM", type: "direct", lastActivity: nil))
        #expect(model.settings.roomID == "room")
        #expect(model.savedSettings.roomID.isEmpty)
        #expect(model.hasUnsavedChanges)
        #expect(model.nextSetupStep == .models)
        model.discardSettingsChanges()
        #expect(!model.hasUnsavedChanges)
        #expect(model.settings.roomID.isEmpty)
    }
}
