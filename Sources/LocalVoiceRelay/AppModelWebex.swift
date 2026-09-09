// Webex authentication, token checks and DM search for AppModel.
import Foundation
import RelayCore

extension AppModel {
    func openTokenPortal() {
        tokenBrowserOpened = openPortal(TokenRecovery.portalURL)
        logs.record(tokenBrowserOpened ? .browserOpened : .browserFailed, category: .webex, level: tokenBrowserOpened ? .info : .warning)
    }
    func presentTokenRenewal() { showTokenRenewal = true; showMainWindow?() }
    func handleAuthenticationFailure() {
        tokenValid = false
        tokenStatus = "認証が無効です。新しいAPI Keyを入力してください。"
        guard tokenRecovery.unauthorized() else { return }
        presentTokenRenewal()
        openTokenPortal()
    }
    func authenticationSucceeded(dismissRenewal: Bool = false) {
        let wasRecovering = tokenRecovery.needsRenewal
        tokenValid = true; keychainNeedsAccess = false; tokenRecovery.authenticated()
        if dismissRenewal || wasRecovering { showTokenRenewal = false }
        if wasRecovering && phase == .error && permissionsReady {
            phase = .stopped; detail = "Webexの認証を更新しました。待受を開始できます。"
        }
        tokenStatus = "有効（\(Date().formatted(date: .omitted, time: .shortened))に確認）"
        logs.record(.tokenValid, category: .webex)
    }
    func connection() async throws -> WebexClient {
        if let client { return client }
        // One noninteractive read per launch; API health checks reuse the in-memory client.
        if tokenReadTask == nil { tokenReadTask = Task { try await TokenStore.read() } }
        let saved: String?
        do { saved = try await tokenReadTask!.value }
        catch {
            if let client { return client }
            keychainNeedsAccess = error is TokenReadError
            throw error
        }
        if let client { return client }
        guard let token = saved, !token.isEmpty else { throw RelayError.message("設定のWebex欄でトークンをキーチェーンに保存してください。") }
        let result = WebexClient(token: token); client = result; return result
    }
    func authorizeSavedToken() async {
        guard canConfigure else { return }
        cancelRoomSearch()
        busy = true; defer { busy = false }
        do {
            guard let token = try await TokenStore.authorize(), !token.isEmpty else {
                throw RelayError.message("保存済みトークンがありません。アプリ内で入力して保存してください。")
            }
            credentialEpoch = UUID(); client = WebexClient(token: token); tokenReadTask = nil
            if permissionsReady, phase == .error { phase = .stopped }
            detail = "保存済みトークンを読み込みました。Webexで有効性を確認します。"
            await checkToken()
        } catch { keychainNeedsAccess = error is TokenReadError; tokenStatus = error.localizedDescription; logs.failure(error, category: .webex) }
    }
    func saveToken() async {
        guard canConfigure, !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelRoomSearch()
        busy = true; defer { busy = false; tokenInput = "" }
        do {
            let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = WebexClient(token: token)
            let person = try await candidate.me()
            try await TokenStore.write(token)
            tokenReadTask = nil
            credentialEpoch = UUID(); client = candidate; ownID = person.id
            authenticationSucceeded(dismissRenewal: true)
            logs.record(.tokenSaved, category: .webex)
            if permissionsReady { phase = .stopped }
            detail = "認証を確認しました。送信先DMを選んでください。"
            busy = false; loadRooms()
        } catch { tokenStatus = error.localizedDescription; fail(error) }
    }
    func checkToken(silent: Bool = false) async {
        let current = credentialEpoch
        guard tokenCheckEpoch != current else { return }
        tokenCheckEpoch = current; checkingToken = true
        defer { if tokenCheckEpoch == current { tokenCheckEpoch = nil; checkingToken = false } }
        do {
            let person = try await connection().me()
            guard current == credentialEpoch else { return }
            ownID = person.id
            authenticationSucceeded()
        } catch {
            guard current == credentialEpoch else { return }
            tokenValid = false; tokenStatus = error.localizedDescription
            if case RelayError.unauthorized = error { fail(error) }
            else if !silent { fail(error) }
            else { logs.failure(error, category: .webex) }
        }
    }
    func loadRooms() { searchRooms(debounce: false) }
    func cancelRoomSearch() {
        roomSearchTask?.cancel(); roomSearchID = UUID()
        if roomsLoading { roomSearchStatus = "DM検索を停止しました。更新ボタンで再開できます。" }
        roomsLoading = false
    }
    func searchRooms(debounce: Bool = true) {
        guard canConfigure else { return }
        roomSearchTask?.cancel()
        let id = UUID(), filter = query
        roomSearchID = id; rooms = []; roomsLoading = true
        roomSearchStatus = "最近のやりとり順に、一致するDMを最大5件探しています。"
        roomSearchTask = Task {
            defer { if roomSearchID == id { roomsLoading = false } }
            do {
                if debounce { try await Task.sleep(nanoseconds: 400_000_000) }
                let result = try await connection().rooms(matching: filter)
                try Task.checkCancellation()
                guard roomSearchID == id, query == filter else { return }
                rooms = result
                logs.record(.roomsLoaded, category: .webex, metrics: [.count: Double(result.count)])
                roomSearchStatus = result.isEmpty ? "条件に一致するDMはありません。" : "\(result.count)件 • 最近のやりとり順 • 最大5件"
            } catch {
                guard !Task.isCancelled, roomSearchID == id else { return }
                roomSearchStatus = error.localizedDescription
                if case RelayError.unauthorized = error { fail(error) } else { logs.failure(error, category: .webex) }
            }
        }
    }
    func selectRoom(_ room: Room) {
        guard canConfigure else { return }
        settings.roomID = room.id; settings.roomTitle = room.title
    }
    func validateDestination() throws {
        try settings.validate()
        guard !settings.roomID.isEmpty else { throw RelayError.message("送信先DMを選んでください。") }
    }
}
