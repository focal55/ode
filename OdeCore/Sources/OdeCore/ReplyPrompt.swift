import Foundation

/// The same drafts in the shape OpenAI-compatible servers return, for decoding JSON answers.
public struct ReplyDraftsJSON: Decodable, Sendable {
    public struct Option: Decodable, Sendable {
        public let text: String
        public let why: String
    }

    public let direct: Option
    public let warm: Option
    public let playful: Option
}

public enum DraftLength: String, CaseIterable, Sendable {
    case brief = "Brief"
    case balanced = "Balanced"
    case expansive = "Expansive"

    public var instruction: String {
        switch self {
        case .brief: "Keep each draft under twelve words."
        case .balanced: "Keep each draft to one or two sentences."
        case .expansive: "Each draft can run two to four sentences."
        }
    }
}

/// The drafting prompt, shared by the app and `ode-eval` so a score measures what the app sends.
public enum ReplyPrompt {
    public static let instructions = """
        You draft the next text message that 'You' will send in a conversation. Write as You, in first person, replying \
        to the latest messages. Each draft must be a complete message You could send as-is, answering what was just \
        said. If You promised something that is still open, address it honestly. Match You's tone and capitalization; \
        treat the usual length as a guide, not a limit. Never invent facts, plans or names that are not in the conversation.
        """

    public static func prompt(messages: [Message], name: (String?) -> String, openLoops: [String], steer: String,
                              length: DraftLength, isGroup: Bool, avoid: [String] = []) -> String {
        var lines = [isGroup ? "Group conversation:" : "Conversation:"]
        lines += messages.filter { $0.kind == .text && $0.text != nil }.suffix(12).map { message in
            "\(message.isFromMe ? "You" : name(message.sender)): \(message.text!.prefix(280))"
        }
        if !openLoops.isEmpty { lines += ["", "Things You promised and hasn't done: \(openLoops.joined(separator: "; "))."] }
        if let style = WritingStyle(of: messages).summary { lines.append(style) }
        lines.append(length.instruction)
        if !steer.isEmpty { lines.append("You want this reply to: \(steer)") }
        if !avoid.isEmpty { lines.append("Write something new. Don't reuse these earlier drafts: \(avoid.map { "\"\($0)\"" }.joined(separator: "; "))") }
        return lines.joined(separator: "\n")
    }

    private static var option: [String: Any] {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The complete message You could send as-is."],
                "why": ["type": "string", "description": "Under eight words on why this works."],
            ],
            "required": ["text", "why"],
            "additionalProperties": false,
        ]
    }

    /// JSON schema for structured output from cloud and local servers.
    public static var schema: [String: Any] {
        [
            "type": "object",
            "properties": ["direct": option, "warm": option, "playful": option],
            "required": ["direct", "playful", "warm"],
            "additionalProperties": false,
        ]
    }
}
