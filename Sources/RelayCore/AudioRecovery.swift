import Foundation

public struct AudioRecovery {
    private var attempts: [Date] = []
    public init() {}
    public mutating func reset() { attempts = [] }
    public mutating func permit(at now: Date) -> Bool {
        attempts.removeAll { now.timeIntervalSince($0) >= 30 }
        guard attempts.count < 2 else { return false }
        attempts.append(now)
        return true
    }
}
