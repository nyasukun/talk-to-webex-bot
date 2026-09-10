import Foundation

/// Keep a user-started listening session active without preventing screen locking or display sleep.
@MainActor final class StandbyActivity {
    private let begin: (ProcessInfo.ActivityOptions) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?
    private var preventsSleep: Bool?
    init(begin: @escaping (ProcessInfo.ActivityOptions) -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: $0, reason: "音声アシスタントの常時待受")
    }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }
    func update(listening: Bool, preventSleep: Bool) {
        if listening, token != nil, preventsSleep == preventSleep { return }
        if let token {
            end(token)
            self.token = nil
        }
        preventsSleep = nil
        guard listening else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep]
        if preventSleep { options.insert(.idleSystemSleepDisabled) }
        token = begin(options)
        preventsSleep = preventSleep
    }
}
