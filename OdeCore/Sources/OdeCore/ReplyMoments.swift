import Foundation

/// A real reply you sent, with only what came before it, so a model can be asked to write it
/// and be judged against what you actually said.
public struct ReplyMoment: Sendable, Equatable {
    public let context: [Message]
    public let actual: Message

    public init(context: [Message], actual: Message) {
        self.context = context
        self.actual = actual
    }
}

public enum ReplyMoments {
    /// The first message of each of your replies to them: a text of at least `minWords` words,
    /// sent within `maxGap` of their last text. One-word acknowledgements are left out because
    /// any draft matches them.
    public static func find(in messages: [Message], minWords: Int = 3, maxGap: TimeInterval = 12 * 3600,
                            contextLimit: Int = 200) -> [ReplyMoment] {
        let texts = messages.filter { $0.kind == .text && $0.text?.isEmpty == false }.sorted { $0.date < $1.date }
        var moments: [ReplyMoment] = []
        for index in texts.indices.dropFirst() {
            let reply = texts[index], previous = texts[index - 1]
            guard reply.isFromMe, !previous.isFromMe,
                  reply.date.timeIntervalSince(previous.date) <= maxGap,
                  (reply.text ?? "").split(whereSeparator: \.isWhitespace).count >= minWords else { continue }
            moments.append(ReplyMoment(context: Array(texts[max(0, index - contextLimit)..<index]), actual: reply))
        }
        return moments
    }

    /// A fixed, spread-out sample: chats take turns, and within a chat the order comes from a
    /// hash of each message's guid, so the same history always yields the same set.
    public static func sample(_ byChat: [[ReplyMoment]], count: Int) -> [ReplyMoment] {
        let queues = byChat.map { moments in moments.sorted { stableHash($0.actual.guid) < stableHash($1.actual.guid) } }
        var picked: [ReplyMoment] = []
        var round = 0
        while picked.count < count, queues.contains(where: { round < $0.count }) {
            for queue in queues where round < queue.count && picked.count < count { picked.append(queue[round]) }
            round += 1
        }
        return picked
    }

    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
