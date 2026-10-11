import Foundation

/// The moment a reply left Ode for Messages.
public struct Handoff: Codable, Sendable, Equatable {
    public let conversationID: Int64
    public let at: Date

    public init(conversationID: Int64, at: Date) {
        self.conversationID = conversationID
        self.at = at
    }
}

/// A reply that started in Ode and that you then sent.
public struct Kept: Codable, Sendable, Equatable {
    public let conversationID: Int64
    public let handoffAt: Date
    public let sentAt: Date
    public let messageID: Int64

    public init(conversationID: Int64, handoffAt: Date, sentAt: Date, messageID: Int64) {
        self.conversationID = conversationID
        self.handoffAt = handoffAt
        self.sentAt = sentAt
        self.messageID = messageID
    }
}

public enum KeptDetector {
    public static let window: TimeInterval = 86_400

    /// Any message from you after the handoff counts, edited or not; a tapback is not a reply.
    public static func detect(handoffs: [Handoff], threads: [Int64: [Message]], now: Date = .now) -> (kept: [Kept], pending: [Handoff]) {
        var kept: [Kept] = []
        var pending: [Handoff] = []
        for handoff in handoffs {
            let deadline = handoff.at.addingTimeInterval(window)
            let sent = threads[handoff.conversationID]?.first {
                $0.isFromMe && $0.kind != .reaction && $0.date > handoff.at && $0.date <= deadline
            }
            if let sent {
                kept.append(Kept(conversationID: handoff.conversationID, handoffAt: handoff.at, sentAt: sent.date, messageID: sent.id))
            } else if now <= deadline {
                pending.append(handoff)
            }
        }
        return (kept, pending)
    }
}
