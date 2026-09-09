import Testing
import Foundation
import RelayCore
@testable import LocalVoiceRelay

struct HardeningTests {
    @Test func privateReplacementRepairsPermissionsAndCleansTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = directory.appendingPathComponent("settings.json")
        try Data("before".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try PrivateFiles.write(Data("after".utf8), to: file)
        #expect(try String(contentsOf: file) == "after")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
    }

    @Test func privateReadsRejectOversizedFilesAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("data")
        try PrivateFiles.write(Data(repeating: 1, count: 10), to: file)
        #expect(try PrivateFiles.read(file, maximumBytes: 10).count == 10)
        #expect(throws: (any Error).self) { try PrivateFiles.read(file, maximumBytes: 9) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try PrivateFiles.read(link, maximumBytes: 10) }
        #expect(throws: (any Error).self) { try PrivateFiles.read(directory, maximumBytes: 10) }
    }

    @Test func workerFramingHandlesSplitUnicodeAndMultipleResponses() throws {
        let first = Data("{\"text\":\"日本語\"}".utf8)
        var chunks = [Data(first.prefix(12)), Data(first.dropFirst(12)) + Data("\n{\"done\":true}\n".utf8)]
        var reader = WorkerResponseReader()
        #expect(try reader.readLine { chunks.removeFirst() } == first)
        #expect(try reader.readLine { Issue.record("Buffered response should not need a read"); return Data() } == Data("{\"done\":true}".utf8))
    }

    @Test func workerRejectsTruncatedAndOversizedFrames() throws {
        var partial = [Data("{\"ready\":true}".utf8), Data()]
        var reader = WorkerResponseReader()
        #expect(throws: (any Error).self) { try reader.readLine { partial.removeFirst() } }
        var limited = WorkerResponseReader(maximumBytes: 4)
        #expect(throws: (any Error).self) { try limited.readLine { Data("12345\n".utf8) } }
        var exact = WorkerResponseReader(maximumBytes: 4)
        #expect(try exact.readLine { Data("1234\n".utf8) } == Data("1234".utf8))
    }

    @Test func workerReadsAnOpenPipeWithoutWaitingForTheBufferToFill() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"ready\":true}\n".utf8))
        var reader = WorkerResponseReader()
        #expect(try reader.readLine(from: pipe.fileHandleForReading) == Data("{\"ready\":true}".utf8))
    }

    @Test func offlineChildrenInheritOnlyRuntimeEssentials() {
        let environment = OfflineProcess.environment(from: ["HOME": "/synthetic", "LANG": "ja_JP.UTF-8", "PATH": "/injected",
            "PASSWORD": "sensitive", "SSH_AUTH_SOCK": "sensitive", "AWS_ACCESS_KEY_ID": "sensitive",
            "PYTHONPATH": "injected", "DYLD_INSERT_LIBRARIES": "injected", "UNRECOGNIZED_CREDENTIAL": "sensitive"])
        #expect(environment["HOME"] == "/synthetic")
        #expect(environment["LANG"] == "ja_JP.UTF-8")
        #expect(environment["HF_HUB_OFFLINE"] == "1")
        #expect(environment["PYTHONNOUSERSITE"] == "1")
        #expect(!environment.values.contains("sensitive"))
        #expect(!environment.values.contains("injected"))
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @MainActor @Test func issueDraftProjectsSafeFieldsWithoutSerializingSettingsOrUnknownMetrics() {
        var settings = Settings()
        settings.roomID = "synthetic-private-room"
        settings.roomTitle = "synthetic-private-person"
        settings.wakePhrases = "synthetic-private-wake"
        settings.referenceText = "synthetic-private-speech"
        settings.ttsEngine = "synthetic-private-engine"
        settings.pythonPath = "/synthetic-private-path"
        let entry = LogEntry(id: UUID(), date: Date(), category: .webex, level: .error, event: .sendAmbiguous,
                             metrics: ["synthetic-private-metric": 123, LogMetric.count.rawValue: 2, LogMetric.seconds.rawValue: .infinity])
        let report = IssueReport.draft(settings: settings, phase: .error,
                                      permissions: PermissionSnapshot(microphone: .allowed, screen: false), entries: [entry])
        #expect(!report.contains("synthetic-private"))
        #expect(report.contains(LogEvent.sendAmbiguous.message))
        #expect(report.contains("件数: 2"))
        #expect(!report.contains("inf"))
        #expect(IssueReport.version("sensitive-build-text") == "開発版")
    }

    @MainActor @Test func clearingConversationAlsoClearsThreadTargetAndIsDisabledDuringListening() {
        let model = AppModel(preview: true)
        model.transcript = "synthetic instruction"; model.reply = "synthetic reply"; model.recognizedInput = "synthetic recognition"
        model.lastReplyTarget = ThreadReplyTarget(message: Message(id: "reply", roomId: "room", text: "reply"))
        model.listening = true
        model.clearConversation()
        model.selectRoom(Room(id: "another", title: "another"))
        #expect(!model.reply.isEmpty)
        #expect(model.settings.roomID.isEmpty)
        model.listening = false
        model.clearConversation()
        #expect(model.transcript.isEmpty && model.reply.isEmpty && model.recognizedInput.isEmpty)
        #expect(model.lastReplyTarget == nil)
    }
}
