import AppKit
import AVFoundation
import RelayCore

struct PermissionSnapshot: Equatable {
    enum Microphone: String {
        case allowed = "許可済み"
        case undecided = "未設定"
        case denied = "未許可"
        case restricted = "制限あり"
        var title: String { L10n.key(rawValue) }
    }
    let microphone: Microphone
    let screen: Bool
    func missing(includeScreen: Bool) -> [String] {
        var result: [String] = []
        if microphone != .allowed { result.append(L10n.text("マイク")) }
        if includeScreen && !screen { result.append(L10n.text("画面収録")) }
        return result
    }
    func require(includeScreen: Bool) throws {
        let names = missing(includeScreen: includeScreen)
        guard names.isEmpty else {
            throw RelayError.missingPermissions(names)
        }
    }
}

enum Permissions {
    static func snapshot() -> PermissionSnapshot {
        let mic: PermissionSnapshot.Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .allowed
        case .notDetermined: mic = .undecided
        case .denied: mic = .denied
        case .restricted: mic = .restricted
        @unknown default: mic = .denied
        }
        return PermissionSnapshot(microphone: mic, screen: CGPreflightScreenCaptureAccess())
    }
    static func requireMicrophone() throws { try snapshot().require(includeScreen: false) }
    static func requireScreen() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw RelayError.missingPermissions([L10n.text("画面収録")])
        }
    }
    @MainActor static func configureMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            openPane("Privacy_Microphone")
        }
    }
    @MainActor static func configureScreen() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            openPane("Privacy_ScreenCapture")
        }
    }
    @MainActor private static func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
