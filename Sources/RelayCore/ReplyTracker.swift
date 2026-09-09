import Foundation

/// Stability is a heuristic. Only an explicit parentId proves request correlation.
public struct ReplyTracker {
    public let request: Message
    public let ownPersonID: String
    public let baseline: Set<String>
    public var settleSeconds: TimeInterval
    public var busyPhrases: [String]
    public var requireThreaded: Bool
    private var observed: [String: (body: String, revision: String?, since: Date)] = [:]
    private var spoken = Set<String>()
    private var lastBodies: [String: String] = [:]
    private var busyIDs = Set<String>()
    public private(set) var candidateIDs = Set<String>()
    public private(set) var bodyUpdateCount = 0
    public var busyMessageCount: Int { busyIDs.count }
    public private(set) var interruptedByOtherRequest = false
    public private(set) var readyMessages: [Message] = []

    public init(request: Message, ownPersonID: String, baseline: Set<String>, settleSeconds: TimeInterval,
                busyPhrases: [String], requireThreaded: Bool = false) {
        self.request = request; self.ownPersonID = ownPersonID; self.baseline = baseline
        self.settleSeconds = settleSeconds; self.busyPhrases = busyPhrases; self.requireThreaded = requireThreaded
    }
    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }
    public mutating func ingest(_ messages: [Message], now: Date) -> [String] {
        readyMessages = []
        guard let sent = parseDate(request.created) else { return [] }
        if messages.contains(where: { $0.roomId == request.roomId && $0.personId == ownPersonID &&
            $0.id != request.id && !baseline.contains($0.id) && (parseDate($0.created) ?? .distantPast) >= sent }) {
            interruptedByOtherRequest = true
        }
        guard !interruptedByOtherRequest else { return [] }
        var ready: [String] = []
        for message in messages.sorted(by: { (parseDate($0.created) ?? .distantPast) < (parseDate($1.created) ?? .distantPast) }) {
            guard message.roomId == request.roomId, message.id != request.id,
                  let sender = message.personId, sender != ownPersonID, !baseline.contains(message.id),
                  let created = parseDate(message.created), created >= sent,
                  message.parentId == (request.parentId ?? request.id) || (request.parentId == nil && message.parentId == nil && !requireThreaded) else { continue }
            candidateIDs.insert(message.id)
            let body = message.body, key = normalized(message.body)
            if let previous = lastBodies[message.id], previous != body { bodyUpdateCount += 1 }
            lastBodies[message.id] = body
            let spokenKey = body.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let isBusy = busyPhrases.contains(where: {
                let busy = normalized($0)
                return !busy.isEmpty && key.hasPrefix(busy)
            })
            if isBusy { busyIDs.insert(message.id) }
            guard !key.isEmpty, !isBusy else { observed.removeValue(forKey: message.id); continue }
            let previous = observed[message.id]
            if previous?.body != body || previous?.revision != message.updated {
                observed[message.id] = (body, message.updated, now); continue
            }
            guard let previous, now.timeIntervalSince(previous.since) >= settleSeconds,
                  spoken.insert(spokenKey).inserted else { continue }
            ready.append(message.speechBody)
            readyMessages.append(message)
        }
        return ready
    }
}
