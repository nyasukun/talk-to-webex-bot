import Foundation

public enum VoiceMode: String, Sendable { case message, threadReply }
public enum RelayIndicator: Sendable { case idle, receiving, sent }

public struct VoiceRouter {
    public enum Result: Equatable { case ignored, armed(VoiceMode), command(String, VoiceMode) }
    private var session = WakeSession()
    private var mode = VoiceMode.message
    public init() {}
    public mutating func reset() { session.reset(); mode = .message }
    public mutating func accept(_ text: String, phrases: String, replyPhrases: String, now: Date, timeout: TimeInterval) -> Result {
        let normal = WakeMatcher.command(in: text, phrases: phrases)
        let reply = WakeMatcher.command(in: text, phrases: replyPhrases)
        if normal != nil { mode = .message; session.reset() }
        else if reply != nil { mode = .threadReply; session.reset() }
        let keys = mode == .message ? phrases : replyPhrases
        switch session.accept(text, phrases: keys, now: now, timeout: timeout) {
        case .ignored: mode = .message; return .ignored
        case .armed: return .armed(mode)
        case .command(let text): let target = mode; mode = .message; return .command(text, target)
        }
    }
}

public struct ThreadReplyTarget: Equatable, Sendable {
    public let roomID: String
    public let parentID: String
    public let replyID: String
    public let preview: String
    public init(message: Message) {
        roomID = message.roomId; parentID = message.parentId ?? message.id
        replyID = message.id; preview = message.body
    }
    public func require(roomID: String) throws {
        guard self.roomID == roomID, !parentID.isEmpty else {
            throw RelayError.message("返信先のDMが変わりました。このDMで新しい返信を受け取ってから実行してください。")
        }
    }
}
