// Run with: swift scripts/check-raycast-background.swift '/path/to/Talk to Webex bot.app'
// Uses an unknown use-case ID: no screen capture, microphone, or Webex send occurs.
// Can be run with the app stopped (hidden launch) or already running.
import AppKit
import Foundation

let appPath = CommandLine.arguments.dropFirst().first ?? ""
guard appPath.hasPrefix("/"), appPath.hasSuffix(".app") else {
    fatalError("Pass the absolute path of the signed application bundle")
}
let workspace = NSWorkspace.shared
let initialPID = workspace.frontmostApplication?.processIdentifier
guard workspace.frontmostApplication?.bundleIdentifier != "org.localvoicerelay.app" else {
    fatalError("Run this check with another application in front")
}
let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LocalVoiceRelay/raycast-requests")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
let id = UUID().uuidString, unknownUseCase = UUID().uuidString
let request = directory.appendingPathComponent("\(id).json")
let response = directory.appendingPathComponent("\(id).response.json")
let data = try JSONSerialization.data(withJSONObject: ["useCaseID": unknownUseCase,
    "createdAt": Date().timeIntervalSince1970, "expectedBundleID": "invalid.probe.no-capture"])
guard FileManager.default.createFile(atPath: request.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
    fatalError("Could not create test request")
}
defer {
    try? FileManager.default.removeItem(at: request)
    try? FileManager.default.removeItem(at: response)
}
var activations = 0
let observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: nil) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
       app.bundleIdentifier == "org.localvoicerelay.app" { activations += 1 }
}
defer { workspace.notificationCenter.removeObserver(observer) }
let process = Process()
process.executableURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/LocalVoiceRelay")
process.arguments = ["--dispatch-raycast-request", id]
try process.run()
let deadline = Date().addingTimeInterval(15)
while process.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
guard !process.isRunning else { process.terminate(); fatalError("Request timed out") }
// Include delayed scene activation after request delivery.
RunLoop.current.run(until: Date().addingTimeInterval(1))
let result = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any]
let foregroundPreserved = initialPID == workspace.frontmostApplication?.processIdentifier
let rejected = result?["accepted"] as? Bool == false
print("requestRejected=\(rejected), foregroundPreserved=\(foregroundPreserved), appActivations=\(activations), exit=\(process.terminationStatus)")
guard rejected && foregroundPreserved && activations == 0 && process.terminationStatus == 0 else { exit(1) }
