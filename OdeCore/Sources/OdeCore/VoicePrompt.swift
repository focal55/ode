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

    public static let revisionInstructions = """
        You revise a text message You are about to send. Apply only the change You asked for and keep the rest as it is: \
        the same points, words and tone. Add nothing You didn't ask for. If the change asks to remove something, remove it.
        """

    public static func prompt(messages: [Message], name: (String?) -> String, request: String, isGroup: Bool) -> String {
        (conversation(messages, name: name, isGroup: isGroup) + ["What You said: \(request)"]).joined(separator: "\n")
    }

    public static func revision(messages: [Message], name: (String?) -> String, draft: String, instruction: String,
                                isGroup: Bool) -> String {
        (conversation(messages, name: name, isGroup: isGroup) + ["Your draft: \(draft)", "Change You asked for: \(instruction)"])
            .joined(separator: "\n")
    }

    private static func conversation(_ messages: [Message], name: (String?) -> String, isGroup: Bool) -> [String] {
        var lines = [isGroup ? "Group conversation:" : "Conversation:"]
        lines += messages.filter { $0.kind == .text && $0.text != nil }.suffix(8).map { message in
            "\(message.isFromMe ? "You" : name(message.sender)): \(message.text!.prefix(280))"
        }
        if let style = WritingStyle(of: messages).summary { lines.append(style) }
        return lines
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
        case reportedSpeech
        case dropped([String])
        case droppedNegation
        case tooLong
    }

    private static let questionCues: Set<String> = ["ask", "how", "what", "when", "where", "why", "who", "which", "whether",
                                                    "hows", "whats", "wheres", "whos", "whens", "whys"]
    /// Speech has no question marks, so a clause that opens like a question counts as one.
    private static let questionOpeners: Set<String> = ["can", "could", "would", "will", "should", "do", "does", "did", "is",
                                                       "are", "want", "wanna", "shall"]
    private static let pronouns: Set<String> = ["i", "you", "we", "they", "he", "she", "it"]
    private static let reportedPronouns: Set<String> = ["her", "his", "him", "she", "he", "shes", "hes"]
    private static let clauseBreaks = [" and ", " but ", " so ", " then "]
    private static let negations: Set<String> = ["not", "no", "never", "cant", "cannot", "wont", "dont", "didnt", "isnt",
                                                 "arent", "wasnt", "werent", "shouldnt", "couldnt", "wouldnt", "havent",
                                                 "hasnt", "nope", "nah"]
    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                                "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
                               "eighty": 80, "ninety": 90]
    /// How people shorten words in texts, so matching your style doesn't read as dropping what you said.
    private static let shorthand = [
        "gonna": "going", "wanna": "want", "tmrw": "tomorrow", "tmr": "tomorrow", "min": "minutes", "mins": "minutes",
        "pics": "photos", "pic": "photo", "pictures": "photos", "picture": "photo", "1st": "first", "2nd": "second",
        "3rd": "third", "thx": "thanks", "pls": "please", "plz": "please", "bc": "because", "cuz": "because",
        "tho": "though", "ppl": "people", "b4": "before", "bday": "birthday", "convo": "conversation",
    ]
    private static let stopWords: Set<String> = [
        "that", "this", "with", "have", "from", "they", "them", "their", "there", "what", "when", "where", "which", "will",
        "would", "could", "should", "about", "just", "really", "tell", "text", "know", "said", "says", "been", "were",
        "your", "yours", "also", "then", "than", "into", "some", "okay", "yeah", "like", "want", "make", "sure", "doing",
        "check", "going", "whether",
    ]

    public static func problems(request: String, draft: String) -> [Problem] {
        let spoken = words(request).map { shorthand[$0] ?? $0 }, written = words(draft).map { shorthand[$0] ?? $0 }
        var problems: [Problem] = []
        if questionCount(in: draft) > spokenQuestions(in: request) { problems.append(.addedQuestion) }
        let spokenNumbers = Set(numbers(in: spoken))
        var seen = Set<String>()
        for added in numbers(in: written) where !spokenNumbers.contains(added) && seen.insert(added).inserted {
            problems.append(.addedNumber(added))
        }
        // "ask how her mom is" sent to her should say "your mom"; copying "her mom" talks about her, not to her.
        let draftPairs = Set(zip(written, written.dropFirst()).map { "\($0) \(stem($1))" })
        if zip(spoken, spoken.dropFirst()).contains(where: { reportedPronouns.contains($0) && draftPairs.contains("\($0) \(stem($1))") }) {
            problems.append(.reportedSpeech)
        }
        if spoken.contains(where: negations.contains), !written.contains(where: negations.contains) {
            problems.append(.droppedNegation)
        }
        let writtenStems = Set(written.map(stem))
        let dropped = spoken.filter { word in
            word.count >= 4 && !stopWords.contains(word) && !negations.contains(word) && numbers(in: [word]).isEmpty
                && !writtenStems.contains(stem(word))
        }
        if !dropped.isEmpty { problems.append(.dropped(dropped)) }
        if written.count > spoken.count * 2 + 8 { problems.append(.tooLong) }
        return problems
    }

    /// Questions you asked for: clauses that open like a question or say "ask", plus one for "check in".
    private static func spokenQuestions(in request: String) -> Int {
        var text = " " + request.lowercased() + " "
        for word in clauseBreaks { text = text.replacingOccurrences(of: word, with: ",") }
        let clauses = text.split { ",.;!?".contains($0) }.map { words(String($0)) }.filter { !$0.isEmpty }
        let asked = clauses.filter { clause in
            questionCues.contains(clause[0]) || questionOpeners.contains(clause[0]) || clause.contains("ask")
                || zip(clause, clause.dropFirst()).contains { questionOpeners.contains($0) && pronouns.contains($1) }
        }.count
        let checkIn = zip(words(request), words(request).dropFirst()).contains { $0 == "check" && $1 == "in" }
        return asked + (checkIn ? 1 : 0)
    }

    private static func questionCount(in text: String) -> Int {
        zip([" "] + Array(text), Array(text)).filter { $1 == "?" && $0 != "?" }.count
    }

    /// Digits as written, and number words as digits; "twenty five" is 20, 5 and 25 so "25" matches. "00" says nothing.
    private static func numbers(in words: [String]) -> [String] {
        var found: [String] = []
        for (index, word) in words.enumerated() {
            if let unit = units.firstIndex(of: word) {
                found.append(String(unit))
            } else if let ten = tens[word] {
                found.append(String(ten))
                if index + 1 < words.count, let unit = units.firstIndex(of: words[index + 1]), (1...9).contains(unit) {
                    found.append(String(ten + unit))
                }
            } else if let digits = Int(String(word.prefix(while: \.isNumber))), word.first?.isNumber == true {
                if digits != 0 || word.count == 1 { found.append(String(digits)) }
            }
        }
        return found
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}") }
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }

    static func contentStems(_ text: String) -> [String] {
        words(text).map { shorthand[$0] ?? $0 }.filter { $0.count >= 4 && !stopWords.contains($0) }.map(stem)
    }

    private static func stem(_ word: String) -> String {
        let base = word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
        return String(base.prefix(5))
    }
}

/// What Ode knows that's worth mentioning, offered as a tap rather than written in. Your promises come first.
public enum VoiceSuggestions {
    public struct Suggestion: Equatable, Sendable {
        public let label: String
        /// How to ask for it: a promise is something you'll do, a reminder is said to them, never about them.
        public let instruction: String
    }

    public static func make(openLoops: [String], reminders: [String], draft: String, limit: Int = 3) -> [Suggestion] {
        let covered = Set(VoiceCheck.contentStems(draft))
        var seen = Set<String>()
        var picked: [Suggestion] = []
        let candidates = openLoops.map { ($0, true) } + reminders.map { ($0, false) }
        for (candidate, isPromise) in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            // The first word is usually the verb ("send", "call"); what matters is whether the rest is already said.
            let stems = VoiceCheck.contentStems(text)
            let essential = stems.count > 1 ? Array(stems.dropFirst()) : stems
            if !essential.isEmpty, essential.allSatisfy(covered.contains) { continue }
            let phrase = text.prefix(1).lowercased() + text.dropFirst()
            picked.append(Suggestion(label: text, instruction: isPromise ? "Also say I'll \(phrase)."
                                                                          : "Also mention \(phrase), speaking to them directly."))
            if picked.count == limit { break }
        }
        return picked
    }
}
