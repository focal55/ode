import Foundation

/// Turns what you said out loud into the message you'd send, keeping your words. Shared by the app and `ode-eval`.
public enum VoicePrompt {
    public static let instructions = """
        You turn what You said out loud into the text message You will send. Write it as You, in first person, speaking \
        to them. Turn reported speech into direct speech: "tell her I'm in" becomes "I'm in", and "ask how his knee is" \
        becomes a question to him about his knee. Drop filler words and false starts. Keep every point You made, in the \
        order You made it. Add nothing You didn't say: no new facts, plans, questions, greetings, sign-offs or feelings. \
        Match how You write to this person: capitalization, punctuation and length.
        """

    public struct Answer: Decodable, Sendable {
        public let text: String
    }

    public static func prompt(messages: [Message], name: (String?) -> String, request: String, isGroup: Bool) -> String {
        var lines = [isGroup ? "Group conversation:" : "Conversation:"]
        lines += messages.filter { $0.kind == .text && $0.text != nil }.suffix(8).map { message in
            "\(message.isFromMe ? "You" : name(message.sender)): \(message.text!.prefix(280))"
        }
        if let style = WritingStyle(of: messages).summary { lines.append(style) }
        lines.append("What You said: \(request)")
        return lines.joined(separator: "\n")
    }

    public static var schema: [String: Any] {
        [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "The message You will send, and nothing else."]],
            "required": ["text"],
            "additionalProperties": false,
        ]
    }
}

/// A heuristic check that a voice draft kept your words: nothing invented, nothing dropped, no padding.
public enum VoiceCheck {
    public enum Problem: Equatable, Sendable {
        case addedQuestion
        case addedNumber(String)
        case dropped([String])
        case tooLong
    }

    private static let questionCues: Set<String> = ["ask", "how", "what", "when", "where", "why", "who", "which", "whether"]
    private static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                      "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                                      "eighteen", "nineteen", "twenty"]
    private static let stopWords: Set<String> = [
        "that", "this", "with", "have", "from", "they", "them", "their", "there", "what", "when", "where", "which", "will",
        "would", "could", "should", "about", "just", "really", "tell", "text", "know", "said", "says", "been", "were",
        "your", "yours", "also", "then", "than", "into", "some", "okay", "yeah", "like", "want", "make", "sure", "doing",
    ]

    public static func problems(request: String, draft: String) -> [Problem] {
        let spoken = words(request), written = words(draft)
        var problems: [Problem] = []
        if draft.contains("?"), !request.contains("?"), !spoken.contains(where: questionCues.contains) {
            problems.append(.addedQuestion)
        }
        let spokenNumbers = Set(spoken.compactMap(number))
        for added in written.compactMap(number) where !spokenNumbers.contains(added) {
            problems.append(.addedNumber(added))
        }
        let writtenStems = Set(written.map(stem))
        let dropped = spoken.filter { $0.count >= 4 && !stopWords.contains($0) && number($0) == nil && !writtenStems.contains(stem($0)) }
        if !dropped.isEmpty { problems.append(.dropped(dropped)) }
        if written.count > spoken.count * 2 + 8 { problems.append(.tooLong) }
        return problems
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}") }
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    private static func number(_ word: String) -> String? {
        if word.allSatisfy(\.isNumber) { return word }
        return numberWords.firstIndex(of: word).map(String.init)
    }

    private static func stem(_ word: String) -> String {
        let base = word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
        return String(base.prefix(5))
    }
}
