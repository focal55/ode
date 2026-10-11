import Foundation

/// What a push-to-talk utterance asks Ode to do. Routing is deterministic so it works with no model running.
public enum VoiceIntent: Equatable, Sendable {
    case reply(conversationID: Int64, request: String)
    case edit(String)
    case ask(String)
    case ambiguous([Int64], request: String)
    case unknown(String)

    public struct Person: Sendable {
        public let id: Int64
        public let names: [String]

        public init(id: Int64, names: [String]) {
            self.id = id
            self.names = names
        }

        /// What you'd call them out loud. Bare phone numbers aren't speakable, and a group answers only to its title.
        public static func spokenNames(title: String, nickname: String?, isGroup: Bool) -> [String] {
            guard title.contains(where: \.isLetter) else { return [] }
            var names = [title]
            let words = title.split(separator: " ")
            if !isGroup, words.count > 1 { names.append(String(words[0])) }
            if !isGroup, let nickname, !nickname.isEmpty { names.append(nickname) }
            return names
        }
    }

    private enum Verb { case say, ask, letKnow, checkIn }

    private static let verbs: [(words: [String], kind: Verb)] = [
        (["check", "in", "on"], .checkIn), (["check", "in", "with"], .checkIn),
        (["reply", "to"], .say), (["respond", "to"], .say), (["write", "to"], .say),
        (["tell"], .say), (["text"], .say), (["message"], .say), (["write"], .say), (["send"], .say),
        (["ask"], .ask), (["let"], .letKnow),
    ]
    private static let filler: Set<String> = ["um", "uh", "umm", "uhh", "so", "okay", "ok", "alright", "hey", "ode", "oh", "well"]
    private static let connectors: Set<String> = ["that", "to", "and"]

    public static func parse(_ transcript: String, people: [Person], focused: Int64? = nil) -> VoiceIntent {
        var words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, filler.contains(key(first)) { words.removeFirst() }
        let spoken = words.joined(separator: " ")
        guard !words.isEmpty else { return .unknown("") }
        if focused != nil { return .edit(spoken) }

        let keys = words.map(key)
        if isQuestionToOde(keys) { return .ask(spoken) }

        let verb = verbs.first { keys.starts(with: $0.words) }
        let start = verb?.words.count ?? 0
        guard let (ids, length) = match(keys, at: start, people: people) else { return .unknown(spoken) }

        var rest = Array(words[(start + length)...])
        if verb?.kind == .letKnow, rest.first.map(key) == "know" { rest.removeFirst() }
        while let first = rest.first, connectors.contains(key(first)) || key(first).isEmpty { rest.removeFirst() }
        var request = rest.joined(separator: " ")
        switch verb?.kind {
        case .ask?: if !request.isEmpty { request = "ask " + request }
        case .checkIn?: if request.isEmpty { request = "check in" }
        default: break
        }
        return ids.count == 1 ? .reply(conversationID: ids[0], request: request) : .ambiguous(ids, request: request)
    }

    /// The longest name that starts at `index`, and everyone who answers to it.
    private static func match(_ keys: [String], at index: Int, people: [Person]) -> (ids: [Int64], length: Int)? {
        guard index < keys.count else { return nil }
        var best: (ids: [Int64], length: Int)?
        for person in people {
            for name in person.names {
                let nameKeys = name.split(whereSeparator: \.isWhitespace).map { key(String($0)) }.filter { !$0.isEmpty }
                guard !nameKeys.isEmpty, keys[index...].starts(with: nameKeys) else { continue }
                if nameKeys.count > best?.length ?? 0 {
                    best = ([person.id], nameKeys.count)
                } else if nameKeys.count == best?.length, best?.ids.contains(person.id) == false {
                    best?.ids.append(person.id)
                }
            }
        }
        return best
    }

    private static func isQuestionToOde(_ keys: [String]) -> Bool {
        guard let first = keys.first else { return false }
        return ["who", "whos"].contains(first) || keys.starts(with: ["is", "anyone"]) || keys.starts(with: ["what", "should", "i"])
    }

    private static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
