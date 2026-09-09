import Foundation

public struct TokenRecovery: Sendable {
    public static let portalURL = URL(string: "https://developer.webex.com/messaging/docs/getting-started")!
    public private(set) var needsRenewal = false
    public init() {}
    /// Return true once per invalid-credential episode, until a new credential validates.
    public mutating func unauthorized() -> Bool {
        guard !needsRenewal else { return false }
        needsRenewal = true
        return true
    }
    public mutating func authenticated() { needsRenewal = false }
}
