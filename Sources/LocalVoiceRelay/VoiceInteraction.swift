import Foundation
import RelayCore

/// Keeps the captured context, cumulative transcript and successful deliveries in one lifetime.
@MainActor struct VoiceInteraction {
    private var continuation: UtteranceContinuation
    private(set) var draft: AppModel.Draft?
    private(set) var delivery: AppModel.Delivery?
    private(set) var sentIDs = Set<String>()
    private(set) var acceptingInput = true
    private(set) var needsDelivery = false
    let mode: VoiceMode
    var text: String { continuation.text }

    init(command: String, speech: SpeechInterval, seconds: TimeInterval, mode: VoiceMode = .message) {
        continuation = UtteranceContinuation(text: command, speech: speech, seconds: seconds)
        self.mode = mode
    }

    mutating func shift(by seconds: TimeInterval) { continuation.shift(by: seconds) }

    func accepts(_ speech: SpeechInterval) -> Bool {
        continuation.accepts(speech)
    }

    func shouldWait(now: Date, pending: SpeechInterval?) -> Bool {
        acceptingInput && continuation.shouldWait(now: now, pending: pending)
    }

    mutating func closeInput() {
        acceptingInput = false
    }

    mutating func setDraft(_ draft: AppModel.Draft) {
        self.draft = draft
        needsDelivery = true
    }

    mutating func append(_ text: String, speech: SpeechInterval) throws -> AppModel.Draft? {
        guard acceptingInput, let previous = draft else { return nil }
        var continued = continuation
        guard continued.append(text, speech: speech) else { return nil }
        // Render before committing so a rejected message cannot leave a partial update.
        let body = try MessageTemplate.render(previous.settings.template, transcript: continued.text,
                                              ocr: previous.screen?.ocr, screen: previous.screen != nil)
        let draft = AppModel.Draft(body: body, screen: previous.screen, settings: previous.settings, thread: previous.thread)
        continuation = continued
        self.draft = draft
        needsDelivery = true
        return draft
    }

    mutating func recordDelivery(_ delivery: AppModel.Delivery) {
        sentIDs.insert(delivery.sent.id)
        self.delivery = delivery
        needsDelivery = false
    }
}
