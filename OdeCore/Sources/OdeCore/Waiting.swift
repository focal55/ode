import Foundation

/// Something a person is waiting on from you, for the home list.
public struct Waiting: Sendable, Equatable, Identifiable {
    /// In priority order: the list shows asked before unanswered before promised before quiet.
    public enum Kind: Int, Sendable, Comparable {
        case asked, unanswered, promised, quiet

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let conversationID: Int64
    public let kind: Kind
    public let text: String
    /// What the draft composer is asked to do when you reply from the list.
    public let steer: String
    /// When it started waiting; the list shows the oldest first within a kind.
    public let since: Date
    /// A dismissal lasts until a message newer than this arrives.
    public let newestMessageID: Int64
    public var id: Int64 { conversationID }

    public init(conversationID: Int64, kind: Kind, text: String, steer: String, since: Date, newestMessageID: Int64) {
        self.conversationID = conversationID
        self.kind = kind
        self.text = text
        self.steer = steer
        self.since = since
        self.newestMessageID = newestMessageID
    }
}

extension Waiting {
    static let minimumAge: TimeInterval = 3_600
    static let maximumAge: TimeInterval = 21 * 86_400

    /// Their messages since your last one, in a 1:1 conversation. `messages` must be in date order.
    /// Younger than an hour isn't waiting yet; older than three weeks is left to `quiet`.
    public static func unanswered(in conversation: Conversation, messages: [Message], now: Date = .now) -> Waiting? {
        guard !conversation.isGroup else { return nil }
        let start = messages.lastIndex { $0.isFromMe && isSpoken($0) }.map { $0 + 1 } ?? messages.startIndex
        let after = messages[start...]
        // Only the window counts: someone you never replied to shouldn't carry years of history.
        let theirs = after.filter { !$0.isFromMe && isSpoken($0) && now.timeIntervalSince($0.date) <= maximumAge }
        guard let latest = theirs.last, let first = theirs.first else { return nil }
        guard !after.contains(where: { $0.isFromMe && $0.kind == .reaction && $0.date >= latest.date }) else { return nil }
        guard now.timeIntervalSince(latest.date) >= minimumAge else { return nil }
        guard let shown = theirs.last(where: { !isCloser($0.text) }) else { return nil }

        let asked = theirs.contains { $0.text?.contains("?") == true }
        return Waiting(conversationID: conversation.id, kind: asked ? .asked : .unanswered, text: display(shown),
                       steer: asked ? "answer their question" : "reply to their last message",
                       since: first.date, newestMessageID: newestSpokenID(in: messages))
    }

    /// Messages stores a photo as U+FFFC in the text, alone or before a caption.
    private static func display(_ message: Message) -> String {
        let text = (message.text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return message.textSource == .undecodable ? "Message" : "Attachment"
    }

    /// The newest message anyone wrote, so tapbacks don't lift a dismissal. `messages` must be in date order.
    public static func newestSpokenID(in messages: [Message]) -> Int64 {
        messages.last(where: isSpoken)?.id ?? 0
    }

    /// Text and attachments, plus messages that couldn't be decoded: those were still written.
    static func isSpoken(_ message: Message) -> Bool {
        message.kind == .text || message.kind == .attachmentOnly || message.textSource == .undecodable
    }

    private static let closers: Set<String> = [
        "ok", "okay", "k", "kk", "thanks", "thank you", "thx", "ty", "lol", "haha", "hahaha", "lmao", "nice", "cool",
        "sounds good", "got it", "np", "no problem", "you too", "will do", "perfect", "great",
        "talk soon", "talk later", "ttyl", "later", "bye", "night", "good night", "goodnight", "gn", "love you", "love ya",
        "ily", "see you", "see ya", "cya", "see you soon", "deal", "bet", "yep", "yup", "sure", "for sure", "sounds great",
        "all good", "no worries", "same",
    ]
    private static let closingEmoji: Set<Character> = ["👍", "❤", "♥"]

    /// A message that ends an exchange and doesn't need a reply.
    static func isCloser(_ text: String?) -> Bool {
        guard let text else { return false }
        // Skin tones and the emoji variation selector don't change what a 👍 or ❤️ means.
        let plain = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F
        }))
        let trimmed = plain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("?") else { return false }
        if trimmed.allSatisfy({ closingEmoji.contains($0) || $0.isWhitespace }) { return true }
        // "K, talk soon" is two closers in a row, not a message that needs an answer.
        let clauses = trimmed.replacingOccurrences(of: " and ", with: ",")
            .split { ",.!;".contains($0) }
            .map { clause -> String in
                var core = Substring(clause)
                while let last = core.last, last.isPunctuation || last.isWhitespace || isEmoji(last) { core = core.dropLast() }
                return core.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return !clauses.isEmpty && clauses.allSatisfy(closers.contains)
    }

    /// Emoji, but not the digits and symbols Unicode also flags as emoji-capable.
    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }
    }
}

extension Waiting {
    private static let promisePrefix = "follow up on: "

    /// Your promise in your words, for Ode to say aloud; nil for anything that isn't a promise.
    public var promise: String? {
        kind == .promised && steer.hasPrefix(Self.promisePrefix) ? String(steer.dropFirst(Self.promisePrefix.count)) : nil
    }

    /// A promise the on-device model confirmed is still open.
    public static func promised(in conversation: Conversation, task: String, made: Date, newestMessageID: Int64) -> Waiting {
        let phrase = task.prefix(1).lowercased() + task.dropFirst()
        return Waiting(conversationID: conversation.id, kind: .promised, text: "You said you'd \(phrase)",
                       steer: promisePrefix + phrase, since: made, newestMessageID: newestMessageID)
    }

    /// A 1:1 relationship well past its usual gap between long conversations.
    public static func quiet(in conversation: Conversation, metrics: RelationshipMetrics, newestMessageID: Int64,
                             now: Date = .now) -> Waiting? {
        guard !conversation.isGroup else { return nil }
        for case .overdue(let since, let usual) in metrics.observations(now: now) {
            return Waiting(conversationID: conversation.id, kind: .quiet,
                           text: "You usually talk \(every(usual)); it's been \(been(since))", steer: "reconnect",
                           since: now.addingTimeInterval(-since), newestMessageID: newestMessageID)
        }
        return nil
    }

    /// One row per conversation under its most urgent kind, most urgent first and oldest first within a kind.
    /// `dismissed` maps a conversation to the newest message id when it was dismissed.
    public static func rank(_ items: [Waiting], dismissed: [Int64: Int64] = [:]) -> [Waiting] {
        Dictionary(grouping: items, by: \.conversationID).values
            .compactMap { group in group.min { ($0.kind, $0.since) < ($1.kind, $1.since) } }
            .filter { item in dismissed[item.conversationID].map { item.newestMessageID > $0 } ?? true }
            .sorted { ($0.kind, $0.since, $0.conversationID) < ($1.kind, $1.since, $1.conversationID) }
    }

    static func every(_ interval: TimeInterval) -> String {
        let (count, unit) = span(interval)
        return count == 1 ? "every \(unit)" : "every \(count) \(unit)s"
    }

    static func been(_ interval: TimeInterval) -> String {
        let (count, unit) = span(interval)
        return count == 1 ? "a \(unit)" : "\(count) \(unit)s"
    }

    private static func span(_ interval: TimeInterval) -> (count: Int, unit: String) {
        let days = max(1, Int((interval / 86_400).rounded()))
        if days < 14 { return (days, "day") }
        if days < 60 { return (Int((Double(days) / 7).rounded()), "week") }
        return (Int((Double(days) / 30).rounded()), "month")
    }
}
