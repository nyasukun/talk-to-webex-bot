import Foundation
import Security
import RelayCore

struct PrivateStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalVoiceRelay")
    }
    static func prepare() throws {
        try PrivateFiles.prepareDirectory(directory)
    }
    static func clearTransient() {
        let temporary = directory.appendingPathComponent("transient")
        for url in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  ["wav", "txt"].contains(url.pathExtension) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    static func load() -> Settings {
        var settings = Settings()
        if let data = try? PrivateFiles.read(directory.appendingPathComponent("settings.json"), maximumBytes: 1_000_000),
           let decoded = try? decodeSettings(data) { settings = decoded }
        if settings.pythonPath.isEmpty { settings.pythonPath = directory.appendingPathComponent("runtime/.venv/bin/python").path }
        if settings.asrModelPath.isEmpty { settings.asrModelPath = directory.appendingPathComponent("models/whisper").path }
        let standard = directory.appendingPathComponent("models/voice-1.7b").path
        let small = directory.appendingPathComponent("models/voice").path
        settings.resolveVoiceModel(standard: standard, small: small,
                                   standardExists: FileManager.default.fileExists(atPath: standard + "/config.json"),
                                   smallExists: FileManager.default.fileExists(atPath: small + "/config.json"))
        return settings
    }
    static func decodeSettings(_ data: Data) throws -> Settings {
        try SettingsCodec.decode(data)
    }

    static func temporaryFile(extension suffix: String) throws -> URL {
        try prepare()
        let temporary = directory.appendingPathComponent("transient")
        try PrivateFiles.prepareDirectory(temporary)
        let file = temporary.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RelayError.message("一時ファイルを作成できません。")
        }
        return file
    }
    static func save(_ settings: Settings) throws {
        try prepare()
        let url = directory.appendingPathComponent("settings.json")
        try PrivateFiles.write(JSONEncoder().encode(settings), to: url)
    }
}

struct TokenKeychainOperations: Sendable {
    var copy: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var add: @Sendable ([String: Any]) -> OSStatus

    static let live = Self(copy: { query in
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }, update: { query, changes in
        SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    }, add: { query in SecItemAdd(query as CFDictionary, nil) })
}

struct TokenReadError: LocalizedError {
    let status: OSStatus
    let interactive: Bool
    var errorDescription: String? {
        interactive
            ? "macOSが保存済みトークンの読み込みを許可しませんでした（\(status)）。確認画面が出なかった場合は、キーチェーンのロック状態とアプリの署名を確認してください。"
            : "保存済みトークンを自動では読み込めませんでした（\(status)）。「保存済みトークンを読み込む」でmacOSのアクセス確認を進めてください。"
    }
}

struct TokenStore {
    // Serialize legacy keychain calls, including the process-wide interaction flag.
    private static let queue = DispatchQueue(label: "org.localvoicerelay.keychain")
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.localvoicerelay.app",
         kSecAttrAccount as String: "webex-token"]
    }
    private static func perform<T: Sendable>(interactive: Bool, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result {
                    var previous: DarwinBoolean = false
                    guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                          SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else {
                        throw RelayError.message("キーチェーンのアクセス方法を設定できません。")
                    }
                    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
                    return try body()
                }
                continuation.resume(with: result)
            }
        }
    }
    static func read(using operations: TokenKeychainOperations = .live) async throws -> String? {
        try await perform(interactive: false) { try readItem(interactive: false, using: operations) }
    }
    private static func readItem(interactive: Bool, using operations: TokenKeychainOperations) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        if status == errSecUserCanceled { throw RelayError.message("キーチェーンの読み込みをキャンセルしました。自動では再試行しません。") }
        guard status == errSecSuccess, let data else {
            throw TokenReadError(status: status, interactive: interactive)
        }
        guard let value = String(data: data, encoding: .utf8) else { throw RelayError.message("保存済みトークンの形式を読み取れません。アプリ内で保存し直してください。") }
        return value
    }
    static func authorize(using operations: TokenKeychainOperations = .live) async throws -> String? {
        // One read only. Replacing an existing ACL itself requires separate owner approval.
        try await perform(interactive: true) { try readItem(interactive: true, using: operations) }
    }
    static func write(_ value: String, using operations: TokenKeychainOperations = .live) async throws {
        try await perform(interactive: true) { try writeItem(value, using: operations) }
    }
    private static func writeItem(_ value: String, using operations: TokenKeychainOperations) throws {
        let data = Data(value.utf8)
        let status = operations.update(query, [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var query = query
            query[kSecValueData as String] = data
            // The default ACL of a new item trusts only its creating application.
            let added = operations.add(query)
            guard added == errSecSuccess else { throw RelayError.message("キーチェーンに保存できません（\(added)）。") }
        } else if status != errSecSuccess { throw RelayError.message("キーチェーンを更新できません（\(status)）。") }
    }
}
