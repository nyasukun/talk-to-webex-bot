import AppKit
import RelayCore

/// Command-line mode never creates AppModel, captures screens, or reads tokens.
/// Those operations belong to the running GUI app, with its existing macOS permissions.
@MainActor enum RaycastCommand {
    static func run(arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 1, let id = UUID(uuidString: arguments[0]) else {
                throw RelayError.message("Usage: --run-screen-use-case <UUID>")
            }
            let target = try restoredApplication()
            print(try submit(id: id, expectedBundleID: target))
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    static func dispatchExisting(arguments: [String]) -> Int32 {
        do {
            guard arguments.count == 1, let id = UUID(uuidString: arguments[0]) else {
                throw RelayError.message("Usage: --dispatch-raycast-request <UUID>")
            }
            try deliver(id: id, applicationPath: Bundle.main.bundleURL.path)
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    private static func restoredApplication() throws -> String {
        let started = Date(), deadline = started.addingTimeInterval(3)
        var previousPID: pid_t?, stableSince = started
        while Date() < deadline {
            let app = NSWorkspace.shared.frontmostApplication
            if previousPID != app?.processIdentifier { previousPID = app?.processIdentifier; stableSince = Date() }
            if let bundle = app?.bundleIdentifier,
               !["com.raycast.macos", "org.localvoicerelay.app", "com.apple.loginwindow"].contains(bundle),
               Date().timeIntervalSince(started) >= 0.3, Date().timeIntervalSince(stableSince) >= 0.2 {
                return bundle
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw RelayError.message(L10n.text("対象のアプリを前面にしてからRaycastを開き直してください。"))
    }

    static func submit(id: UUID, expectedBundleID: String, directory: URL = PrivateStorage.directory,
                       dispatch: @MainActor (URL, String) throws -> Void = dispatchURL) throws -> String {
        let data = try PrivateFiles.read(directory.appendingPathComponent("screen-use-cases.json"))
        let catalog = try JSONDecoder().decode(RaycastBridge.Catalog.self, from: data)
        guard catalog.version == 1, catalog.applicationPath.hasPrefix("/"), catalog.applicationPath.hasSuffix(".app"),
              catalog.useCases.contains(where: { $0.id == id }) else {
            throw RelayError.message(L10n.text("このユースケースは削除または無効化されています。Raycastの一覧を更新してください。"))
        }
        guard !expectedBundleID.isEmpty,
              !["com.raycast.macos", "org.localvoicerelay.app", "com.apple.loginwindow"].contains(expectedBundleID) else {
            throw RelayError.message(L10n.text("対象のアプリを前面にしてからRaycastを開き直してください。"))
        }
        let requestID = UUID(), requests = directory.appendingPathComponent("raycast-requests")
        let requestPath = requests.appendingPathComponent("\(requestID.uuidString).json")
        let responsePath = requests.appendingPathComponent("\(requestID.uuidString).response.json")
        let request = RaycastBridge.Request(useCaseID: id, createdAt: Date().timeIntervalSince1970, expectedBundleID: expectedBundleID)
        try PrivateFiles.write(JSONEncoder().encode(request), to: requestPath)
        defer {
            try? FileManager.default.removeItem(at: requestPath)
            try? FileManager.default.removeItem(at: responsePath)
        }
        try dispatch(URL(string: "talk-to-webex-bot://run?request=\(requestID.uuidString)")!, catalog.applicationPath)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responsePath.path) {
                let response = try JSONDecoder().decode(RaycastBridge.Response.self,
                    from: PrivateFiles.read(responsePath, maximumBytes: 16_384))
                guard response.accepted else { throw RelayError.message(response.message) }
                return response.message
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw RelayError.message(L10n.text("アプリの応答を確認できません。Talk to Webex botで状態を確認してください。自動再実行はしません。"))
    }

    private static func dispatchURL(_ url: URL, applicationPath: String) throws {
        guard let id = RaycastBridge.requestID(from: url) else { throw RelayError.message("Invalid request ID") }
        try deliver(id: id, applicationPath: applicationPath)
    }

    static func deliver(id: UUID, applicationPath: String, directory: URL = PrivateStorage.directory,
                        ensureRunning: @MainActor (String) throws -> Void = ensureRunning) throws {
        let requests = directory.appendingPathComponent("raycast-requests")
        let request = requests.appendingPathComponent("\(id.uuidString).json")
        let response = requests.appendingPathComponent("\(id.uuidString).response.json")
        guard FileManager.default.fileExists(atPath: request.path) else { throw RelayError.message("Missing request") }
        try ensureRunning(applicationPath)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: response.path) { return }
            DistributedNotificationCenter.default().postNotificationName(RaycastBridge.requestNotification,
                object: applicationPath, userInfo: ["request": id.uuidString], deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw RelayError.message(L10n.text("アプリの応答を確認できません。Talk to Webex botで状態を確認してください。自動再実行はしません。"))
    }

    private static func ensureRunning(_ applicationPath: String) throws {
        let url = URL(fileURLWithPath: applicationPath).standardizedFileURL
        // Most requests take this branch: do not send reopen/open-URL Apple Events to
        // a running SwiftUI app, even with `open -g`, since its scene may become active.
        if NSWorkspace.shared.runningApplications.contains(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == url }) { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Only a stopped app needs Launch Services. Launch hidden without a URL, then
        // deliver the same nonce until its notification observer is ready.
        process.arguments = ["-g", "-j", "-a", applicationPath]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RelayError.message(L10n.text("Talk to Webex botを起動できません。アプリを起動してから選び直してください。"))
        }
    }
}
