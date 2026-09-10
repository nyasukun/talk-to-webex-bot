import Foundation

public struct WakeSession {
    public enum Result: Equatable { case ignored, armed, command(String) }
    private var armedAt: Date?
    public init() {}
    public mutating func reset() { armedAt = nil }
    public func isArmed(now: Date, timeout: TimeInterval) -> Bool {
        armedAt.map { now.timeIntervalSince($0) < timeout } ?? false
    }
    public mutating func accept(_ text: String, phrases: String, now: Date, timeout: TimeInterval) -> Result {
        let command = WakeMatcher.command(in: text, phrases: phrases)
        if let command {
            if command.isEmpty {
                armedAt = now
                return .armed
            }
            armedAt = nil
            return .command(command)
        }
        if isArmed(now: now, timeout: timeout), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            armedAt = nil
            return .command(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        armedAt = nil
        return .ignored
    }
}
