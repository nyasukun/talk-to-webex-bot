import RelayCore
import Testing
import Foundation
import Security
@testable import LocalVoiceRelay

private final class KeychainCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) { lock.withLock { events.append(event) } }
    var values: [String] { lock.withLock { events } }
}

@Suite(.serialized) struct TokenStoreTests {
    @Test func explicitLoadReadsOnceWithoutChangingPermissions() async throws {
        let calls = KeychainCalls()
        let backend = TokenKeychainOperations(copy: { query in
            calls.add("read")
            #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
            #expect(query[kSecReturnData as String] as? Bool == true)
            return (errSecSuccess, Data("placeholder".utf8))
        }, update: { _, _ in calls.add("update"); return errSecSuccess }, add: { _ in calls.add("add"); return errSecSuccess })
        let loaded = try await TokenStore.authorize(using: backend)
        #expect(loaded == "placeholder")
        #expect(calls.values == ["read"])
    }

    @Test func deniedReadIsNotRetried() async {
        let calls = KeychainCalls()
        let backend = TokenKeychainOperations(copy: { _ in
            calls.add("read"); return (errSecUserCanceled, nil)
        }, update: { _, _ in calls.add("update"); return errSecSuccess }, add: { _ in calls.add("add"); return errSecSuccess })
        do { _ = try await TokenStore.authorize(using: backend); Issue.record("Expected cancellation") }
        catch { #expect([L10n.text("キーチェーンの読み込みをキャンセルしました。自動では再試行しません。", language: .japanese), L10n.text("キーチェーンの読み込みをキャンセルしました。自動では再試行しません。", language: .english)].contains(error.localizedDescription)) }
        #expect(calls.values == ["read"])
    }

    @Test func automaticReadDisallowsInteractionAndRestoresIt() async throws {
        var previous: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess)
        let backend = TokenKeychainOperations(copy: { _ in
            var allowed: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
            #expect(!allowed.boolValue)
            return (errSecItemNotFound, nil)
        }, update: { _, _ in Issue.record("Unexpected write"); return errSecSuccess }, add: { _ in Issue.record("Unexpected add"); return errSecSuccess })
        #expect(try await TokenStore.read(using: backend) == nil)
        var restored: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
        #expect(restored.boolValue == previous.boolValue)
    }

    @Test func failedAutomaticAndManualReadsHaveDistinctRecoveryInstructions() async {
        for interactive in [false, true] {
            let backend = TokenKeychainOperations(copy: { _ in
                var allowed: DarwinBoolean = false
                #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                #expect(allowed.boolValue == interactive)
                return (errSecAuthFailed, nil)
            }, update: { _, _ in Issue.record("Unexpected write"); return errSecSuccess }, add: { _ in Issue.record("Unexpected add"); return errSecSuccess })
            do {
                if interactive { _ = try await TokenStore.authorize(using: backend) }
                else { _ = try await TokenStore.read(using: backend) }
                Issue.record("Expected access error")
            } catch {
                let failure = error as? TokenReadError
                #expect(failure?.status == errSecAuthFailed)
                #expect(failure?.interactive == interactive)
                #expect(error.localizedDescription.contains(interactive ? "ロック状態" : "自動では") || error.localizedDescription.contains(interactive ? "locked" : "automatically"))
            }
        }
    }

    @Test func tokenUpdateChangesOnlyValue() async throws {
        let calls = KeychainCalls()
        let backend = TokenKeychainOperations(copy: { _ in calls.add("read"); return (errSecSuccess, nil) }, update: { _, changes in
            calls.add("update")
            #expect(Set(changes.keys) == [kSecValueData as String])
            return errSecSuccess
        }, add: { _ in calls.add("add"); return errSecSuccess })
        try await TokenStore.write("placeholder", using: backend)
        #expect(calls.values == ["update"])
    }

    @Test func tokenCreatesItemOnlyWhenMissing() async throws {
        let calls = KeychainCalls()
        let backend = TokenKeychainOperations(copy: { _ in calls.add("read"); return (errSecSuccess, nil) }, update: { _, _ in
            calls.add("update"); return errSecItemNotFound
        }, add: { query in
            calls.add("add")
            #expect(query[kSecAttrAccess as String] == nil)
            #expect(query[kSecValueData as String] as? Data == Data("placeholder".utf8))
            return errSecSuccess
        })
        try await TokenStore.write("placeholder", using: backend)
        #expect(calls.values == ["update", "add"])
    }
}
