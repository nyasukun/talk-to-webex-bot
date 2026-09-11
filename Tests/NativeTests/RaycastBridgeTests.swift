import Foundation
import AppKit
import Testing
import RelayCore
@testable import LocalVoiceRelay

@MainActor struct RaycastBridgeTests {
    @Test func delegateDeliversURLsAndCommandReceivesAcknowledgmentExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RaycastBridge(directory: root), delegate = RelayApplicationDelegate()
        let entry = RaycastBridge.Entry(id: UUID(), name: "test", readReplies: false, hotkey: nil, confirmBeforeSending: true)
        let catalog = RaycastBridge.Catalog(version: 1, applicationPath: "/Applications/Example.app", useCases: [entry])
        try PrivateFiles.write(JSONEncoder().encode(catalog), to: root.appendingPathComponent("screen-use-cases.json"))
        var received = 0
        bridge.start { request in
            #expect(request.useCaseID == entry.id && request.expectedBundleID == "com.apple.TextEdit")
            received += 1
        }
        let result = try RaycastCommand.submit(id: entry.id, expectedBundleID: "com.apple.TextEdit", directory: root) { url, path in
            #expect(path == catalog.applicationPath)
            delegate.application(NSApplication.shared, open: [url])
            #expect(received == 1)
        }
        #expect(!result.isEmpty && received == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raycast-requests").path).isEmpty)
        #expect(throws: (any Error).self) {
            try RaycastCommand.submit(id: UUID(), expectedBundleID: "com.apple.TextEdit", directory: root) { _, _ in received += 1 }
        }
        #expect(received == 1)
        bridge.start { _ in throw RelayError.message("busy") }
        #expect(throws: (any Error).self) {
            try RaycastCommand.submit(id: entry.id, expectedBundleID: "com.apple.TextEdit", directory: root) { url, _ in
                delegate.application(NSApplication.shared, open: [url])
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raycast-requests").path).isEmpty)
    }

    @Test func generatedRootCommandsSyncRenameDeleteAndQuoteUntrustedNamesAndPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RaycastBridge(directory: root)
        var settings = Settings()
        settings.screenUseCases[0].name = "test\nexec bad\r# @raycast.mode fullOutput"
        try bridge.publish(settings)
        let folder = bridge.scriptsDirectory
        let first = folder.appendingPathComponent("talk-\(settings.screenUseCases[0].id.uuidString).sh")
        let content = String(decoding: try PrivateFiles.read(first), as: UTF8.self)
        #expect(content.contains("# @raycast.title talk test exec bad # @raycast.mode fullOutput"))
        #expect(!content.contains("\nexec bad"))
        #expect((try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int) == 0o700)
        let unrelated = folder.appendingPathComponent("personal.sh")
        try Data("do not delete".utf8).write(to: unrelated)
        settings.screenUseCases[0].name = "renamed"
        settings.screenUseCases[1].enabled = false
        try bridge.publish(settings)
        #expect(String(decoding: try PrivateFiles.read(first), as: UTF8.self).contains("# @raycast.title talk renamed"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        settings.screenUseCases = []
        try bridge.publish(settings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["personal.sh"])
        let entry = RaycastBridge.Entry(id: UUID(), name: "$(touch bad)", readReplies: false, hotkey: nil, confirmBeforeSending: false)
        let script = RaycastBridge.command(entry, applicationPath: "/tmp/a'b $(touch bad).app")
        #expect(script.contains("exec '/tmp/a'\"'\"'b $(touch bad).app/Contents/MacOS/LocalVoiceRelay'"))
    }

    @Test func catalogIncludesUnassignedCasesAndExcludesDisabledCasesAndPrivateSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RaycastBridge(directory: root)
        var settings = Settings()
        settings.screenUseCases[0].enabled = false
        settings.screenUseCases.append(ScreenUseCase(name: "custom", prompt: "private prompt"))
        settings.roomID = "private-room"
        try bridge.publish(settings)
        let data = try PrivateFiles.read(root.appendingPathComponent("screen-use-cases.json"))
        let catalog = try JSONDecoder().decode(RaycastBridge.Catalog.self, from: data)
        #expect(catalog.version == 1 && catalog.useCases.count == 2)
        #expect(catalog.useCases.last?.hotkey == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("private"))
    }

    @Test func urlRequiresLocalOneUseRequestAndRejectsReplaysExpiredAndUntrustedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = RaycastBridge(directory: root), id = UUID(), now = Date()
        let url = URL(string: "talk-to-webex-bot://run?request=\(id.uuidString)")!
        #expect(RaycastBridge.requestID(from: url) == id)
        for raw in ["talk-to-webex-bot://run?request=../file", "https://run?request=\(id)",
                    "talk-to-webex-bot://run?request=\(id)&prompt=anything", "talk-to-webex-bot://run/\(id)"] {
            #expect(RaycastBridge.requestID(from: URL(string: raw)!) == nil)
        }
        #expect(throws: (any Error).self) { try bridge.consume(id, now: now) }
        func write(age: Double = 0, bundle: String = "com.apple.TextEdit") throws {
            let request = RaycastBridge.Request(useCaseID: ScreenUseCase.defaults[0].id,
                createdAt: now.timeIntervalSince1970 - age, expectedBundleID: bundle)
            try PrivateFiles.write(JSONEncoder().encode(request), to: root.appendingPathComponent("raycast-requests/\(id.uuidString).json"))
        }
        try write()
        #expect(try bridge.consume(id, now: now).useCaseID == ScreenUseCase.defaults[0].id)
        #expect(throws: (any Error).self) { try bridge.consume(id, now: now) }
        for age in [31.0, -1.0] {
            try write(age: age)
            #expect(throws: (any Error).self) { try bridge.consume(id, now: now) }
        }
        for bundle in ["", "com.raycast.macos", "org.localvoicerelay.app", "com.apple.loginwindow"] {
            try write(bundle: bundle)
            #expect(throws: (any Error).self) { try bridge.consume(id, now: now) }
        }
    }

    @Test func largeSettingsRemainReadableWithoutRemovingOtherReadersLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.json"), data = Data(repeating: 32, count: 1_100_000)
        try PrivateFiles.write(data, to: file)
        #expect(try PrivateFiles.read(file) == data)
        #expect(throws: (any Error).self) { try PrivateFiles.read(file, maximumBytes: 1_000_000) }
    }
}
