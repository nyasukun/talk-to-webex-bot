import AppKit
import ScreenCaptureKit
import Vision
import RelayCore

struct ScreenContext: Sendable {
    let png: Data
    let ocr: String

    enum Unavailable: Error { case noWindow, changedWindow, inactiveSession }

    static func sessionAllowsCapture(_ session: [String: Any]?) -> Bool {
        guard let session, session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        // WindowServer provides this lock-state flag; unknown console sessions are excluded above.
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    @MainActor static func capture() async throws -> ScreenContext {
        try Permissions.requireScreen()
        guard sessionAllowsCapture(CGSessionCopyCurrentDictionary() as? [String: Any]) else { throw Unavailable.inactiveSession }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.bundleIdentifier != "com.apple.loginwindow" else {
            throw Unavailable.noWindow
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
            throw Unavailable.changedWindow
        }
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = ordered.compactMap { item -> CGWindowID? in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (item[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return item[kCGWindowNumber as String] as? CGWindowID
        }
        guard let window = ids.compactMap({ id in content.windows.first { $0.windowID == id && $0.frame.width > 50 && $0.frame.height > 50 } }).first else {
            throw Unavailable.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(2, 1920 / max(window.frame.width, window.frame.height))
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard sessionAllowsCapture(CGSessionCopyCurrentDictionary() as? [String: Any]),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
            throw Unavailable.changedWindow
        }
        let context = try await Task.detached(priority: .userInitiated) {
            let text = try recognize(image)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RelayError.message("画像をPNGに変換できません。") }
            return ScreenContext(png: png, ocr: text)
        }.value
        guard sessionAllowsCapture(CGSessionCopyCurrentDictionary() as? [String: Any]),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else {
            throw Unavailable.changedWindow
        }
        return context
    }
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

enum ScreenAttachment {
    @MainActor static func captureIfAvailable(enabled: Bool,
        capture: @MainActor () async throws -> ScreenContext = { try await ScreenContext.capture() }) async throws -> ScreenContext? {
        guard enabled else { return nil }
        do { return try await capture() }
        catch is CancellationError { throw CancellationError() }
        catch RelayError.missingPermissions(let names) { throw RelayError.missingPermissions(names) }
        catch {
            try Task.checkCancellation()
            return nil
        }
    }
}
