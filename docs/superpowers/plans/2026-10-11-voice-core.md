# Voice Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tested core of voice: turn a spoken request into an action ("reply to Maya with these words"), turn your spoken words into the message you'd send without adding anything, and measure how faithful a model is at that.

**Architecture:** Three pure pieces in OdeCore. `VoiceIntent.parse` routes a transcript to a person deterministically (verbs plus name matching, no model). `VoicePrompt` is the "voice keeps your words" drafting prompt, shared by the app and `ode-eval`. `VoiceCheck` is a heuristic faithfulness check (added questions, added numbers, dropped content words, padding) that `ode-eval voice` uses to score a model on a fixed synthetic suite. The app wiring (capture, push-to-talk, composer, Ode speaking) is plan 2b.

**Tech Stack:** Swift 6, Swift Testing, Swift Package Manager (OdeCore), FoundationModels (eval's Apple path).

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (sections "Voice" and "OdeCore (new)": `VoiceIntent`; "Drafting" under Testing).

## Global Constraints

- Intents: `.reply(conversationID:request:)`, `.edit(_)`, `.ask(_)`, `.ambiguous(_:request:)`, `.unknown(_)`.
- Reply verbs: "tell", "text", "message", "reply to", "respond to", "write to", "write", "send", "ask", "check in on", "check in with", "let … know". A name at the very start with no verb also counts as a reply.
- Name matching is deterministic: full title, first name (1:1 conversations whose title has two or more words) and Contacts nickname; case- and punctuation-insensitive; the longest matching name wins; a name shared by several people is ambiguous. Titles with no letters (bare phone numbers) are not speakable.
- Leading filler is ignored: um, uh, umm, uhh, so, okay, ok, alright, hey, ode, oh, well.
- While a person is focused, everything said is an edit.
- Voice drafting adds nothing You didn't say: no new facts, plans, questions, greetings, sign-offs or feelings. It converts reported speech to direct speech and drops filler.
- The voice eval suite is synthetic (no real messages), so its drafts may be printed to the terminal.
- Code style: no comments that restate code, conventional commits, no emojis.
- Commands: prefix Swift commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Review Focus

1. A transcript with trailing punctuation glued to the name ("Tell Maya, I'm in") must still route to Maya and not leak the comma into the request. Covered by `punctuationAfterTheNameIsDropped` in Task 1.
2. Two contacts sharing a first name, where you say the full name, must route to the right one, not be ambiguous. Covered by `aFullNameBeatsASharedFirstName` in Task 1.
3. Saying only a name and a verb ("text Sam") must still open Sam with an empty request, so the app can fall back to Ode's normal drafts. Covered by `aVerbAndNameWithNothingElseIsAnEmptyRequest` in Task 1.
4. "ask" requests may legitimately produce a question; the check must not flag that. Covered by `askedQuestionsAreAllowed` in Task 2.
5. A number spoken as a word ("at ten") rendered as a digit ("at 10") is not an added number. Covered by `numberWordsMatchDigits` in Task 2.

---

### Task 1: VoiceIntent

**Files:**
- Create: `OdeCore/Sources/OdeCore/VoiceIntent.swift`
- Test: `OdeCore/Tests/OdeCoreTests/VoiceIntentTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum VoiceIntent: Equatable, Sendable` with cases `reply(conversationID: Int64, request: String)`, `edit(String)`, `ask(String)`, `ambiguous([Int64], request: String)`, `unknown(String)`.
  - `public struct VoiceIntent.Person: Sendable { public let id: Int64; public let names: [String]; public init(id: Int64, names: [String]) }`
  - `public static func VoiceIntent.Person.spokenNames(title: String, nickname: String?, isGroup: Bool) -> [String]`
  - `public static func VoiceIntent.parse(_ transcript: String, people: [Person], focused: Int64? = nil) -> VoiceIntent`

- [ ] **Step 1: Write the failing tests**

Create `OdeCore/Tests/OdeCoreTests/VoiceIntentTests.swift`:

```swift
import Testing
@testable import OdeCore

@Suite struct VoiceIntentTests {
    let people: [VoiceIntent.Person] = [
        .init(id: 1, names: VoiceIntent.Person.spokenNames(title: "Maya Chen", nickname: nil, isGroup: false)),
        .init(id: 2, names: VoiceIntent.Person.spokenNames(title: "Sam Lee", nickname: nil, isGroup: false)),
        .init(id: 3, names: VoiceIntent.Person.spokenNames(title: "Sam Ortiz", nickname: nil, isGroup: false)),
        .init(id: 4, names: VoiceIntent.Person.spokenNames(title: "Joe Ybarra Sr", nickname: "Dad", isGroup: false)),
        .init(id: 5, names: VoiceIntent.Person.spokenNames(title: "Mamma Ybarra", nickname: "Mom", isGroup: false)),
        .init(id: 6, names: VoiceIntent.Person.spokenNames(title: "Priya", nickname: nil, isGroup: false)),
        .init(id: 7, names: VoiceIntent.Person.spokenNames(title: "+13105550199", nickname: nil, isGroup: false)),
        .init(id: 8, names: VoiceIntent.Person.spokenNames(title: "Ybarra family", nickname: nil, isGroup: true)),
    ]

    func parse(_ text: String, focused: Int64? = nil) -> VoiceIntent { VoiceIntent.parse(text, people: people, focused: focused) }

    @Test func spokenNamesIncludeFirstNameAndNicknameForPeopleOnly() {
        #expect(VoiceIntent.Person.spokenNames(title: "Maya Chen", nickname: "May", isGroup: false) == ["Maya Chen", "Maya", "May"])
        #expect(VoiceIntent.Person.spokenNames(title: "Priya", nickname: nil, isGroup: false) == ["Priya"])
        #expect(VoiceIntent.Person.spokenNames(title: "Ybarra family", nickname: nil, isGroup: true) == ["Ybarra family"])
        #expect(VoiceIntent.Person.spokenNames(title: "+13105550199", nickname: nil, isGroup: false).isEmpty)
    }

    @Test func tellRoutesToThePersonWithTheRestAsTheRequest() {
        #expect(parse("Tell Maya I'm in for Saturday, and ask how her mom's doing.")
                == .reply(conversationID: 1, request: "I'm in for Saturday, and ask how her mom's doing."))
    }

    @Test func leadingFillerIsIgnored() {
        #expect(parse("um okay so text Priya love the new place") == .reply(conversationID: 6, request: "love the new place"))
    }

    @Test func aFullNameBeatsASharedFirstName() {
        #expect(parse("reply to Sam Lee sounds good") == .reply(conversationID: 2, request: "sounds good"))
    }

    @Test func aSharedFirstNameIsAmbiguous() {
        #expect(parse("tell Sam I'm running late") == .ambiguous([2, 3], request: "I'm running late"))
    }

    @Test func letSomeoneKnowDropsKnowAndThat() {
        #expect(parse("let Dad know that I landed") == .reply(conversationID: 4, request: "I landed"))
    }

    @Test func nicknamesMatch() {
        #expect(parse("text mom I'm on my way") == .reply(conversationID: 5, request: "I'm on my way"))
    }

    @Test func checkInWithNothingElseAsksToCheckIn() {
        #expect(parse("Check in on Dad.") == .reply(conversationID: 4, request: "check in"))
    }

    @Test func askKeepsTheAsk() {
        #expect(parse("ask Priya how the new job is going") == .reply(conversationID: 6, request: "ask how the new job is going"))
    }

    @Test func aNameAtTheStartIsAReply() {
        #expect(parse("Maya, running ten minutes late") == .reply(conversationID: 1, request: "running ten minutes late"))
    }

    @Test func punctuationAfterTheNameIsDropped() {
        #expect(parse("Tell Maya, I'm in") == .reply(conversationID: 1, request: "I'm in"))
    }

    @Test func aVerbAndNameWithNothingElseIsAnEmptyRequest() {
        #expect(parse("text Sam Ortiz") == .reply(conversationID: 3, request: ""))
    }

    @Test func groupsAnswerToTheirFullTitle() {
        #expect(parse("tell Ybarra family dinner is at six") == .reply(conversationID: 8, request: "dinner is at six"))
    }

    @Test func questionsToOdeAreAsks() {
        #expect(parse("Who should I check on?") == .ask("Who should I check on?"))
        #expect(parse("hey Ode, is anyone waiting on me") == .ask("is anyone waiting on me"))
    }

    @Test func everythingIsAnEditWhileFocused() {
        #expect(parse("um make it shorter", focused: 1) == .edit("make it shorter"))
        #expect(parse("tell Maya hi", focused: 1) == .edit("tell Maya hi"))
    }

    @Test func unknownNamesAndEmptyTranscriptsAreUnknown() {
        #expect(parse("tell Bob hi") == .unknown("tell Bob hi"))
        #expect(parse("um uh") == .unknown(""))
        #expect(parse("") == .unknown(""))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter VoiceIntentTests 2>&1 | grep -E "error:" | grep -v SwiftCompile | head -3`
Expected: "cannot find 'VoiceIntent' in scope".

- [ ] **Step 3: Implement**

Create `OdeCore/Sources/OdeCore/VoiceIntent.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter VoiceIntentTests 2>&1 | grep -E "✘|Test run"`
Expected: `Test run with 16 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/VoiceIntent.swift OdeCore/Tests/OdeCoreTests/VoiceIntentTests.swift
git commit -m "feat(core): route spoken requests to the right person"
```

---

### Task 2: VoicePrompt and VoiceCheck

**Files:**
- Create: `OdeCore/Sources/OdeCore/VoicePrompt.swift`
- Test: `OdeCore/Tests/OdeCoreTests/VoicePromptTests.swift`

**Interfaces:**
- Consumes: `Message`, `WritingStyle` (existing).
- Produces:
  - `public enum VoicePrompt` with `public static let instructions: String`, `public static func prompt(messages: [Message], name: (String?) -> String, request: String, isGroup: Bool) -> String`, `public static var schema: [String: Any]`, and `public struct Answer: Decodable, Sendable { public let text: String }`.
  - `public enum VoiceCheck` with `public enum Problem: Equatable, Sendable { case addedQuestion, addedNumber(String), dropped([String]), tooLong }` and `public static func problems(request: String, draft: String) -> [Problem]`.

- [ ] **Step 1: Write the failing tests**

Create `OdeCore/Tests/OdeCoreTests/VoicePromptTests.swift`:

```swift
import Foundation
import Testing
@testable import OdeCore

@Suite struct VoicePromptTests {
    @Test func promptCarriesTheConversationAndWhatYouSaid() {
        let messages = [
            Message(id: 1, guid: "1", chatID: 1, sender: "maya@example.com", isFromMe: false, date: .distantPast,
                    text: "Are you still in for Saturday?", textSource: .column, kind: .text),
        ]
        let prompt = VoicePrompt.prompt(messages: messages, name: { _ in "Maya" }, request: "I'm in", isGroup: false)
        #expect(prompt.contains("Maya: Are you still in for Saturday?"))
        #expect(prompt.hasSuffix("What You said: I'm in"))
    }

    @Test func aFaithfulDraftHasNoProblems() {
        #expect(VoiceCheck.problems(request: "I'm in for Saturday, and ask how her mom's doing",
                                    draft: "I'm in for Saturday! How's your mom doing?").isEmpty)
    }

    @Test func askedQuestionsAreAllowed() {
        #expect(VoiceCheck.problems(request: "ask how the new job is going", draft: "How's the new job going?").isEmpty)
    }

    @Test func anInventedQuestionIsFlagged() {
        #expect(VoiceCheck.problems(request: "I'm running late", draft: "I'm running late, want me to grab coffee?")
                .contains(.addedQuestion))
    }

    @Test func anInventedNumberIsFlagged() {
        #expect(VoiceCheck.problems(request: "I'll be there at ten", draft: "I'll be there at 10:30") == [.addedNumber("30")])
    }

    @Test func numberWordsMatchDigits() {
        #expect(VoiceCheck.problems(request: "running ten minutes late", draft: "Running 10 minutes late").isEmpty)
    }

    @Test func droppedPointsAreFlagged() {
        #expect(VoiceCheck.problems(request: "love the place but the kitchen is tiny", draft: "Love the place!")
                == [.dropped(["kitchen", "tiny"])])
    }

    @Test func paddingIsFlagged() {
        let draft = "Sounds good to me, I really appreciate you thinking of me and I can't wait to see you there this weekend"
        #expect(VoiceCheck.problems(request: "sounds good", draft: draft).contains(.tooLong))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter VoicePromptTests 2>&1 | grep -E "error:" | grep -v SwiftCompile | head -3`
Expected: "cannot find 'VoicePrompt' in scope".

- [ ] **Step 3: Implement**

Create `OdeCore/Sources/OdeCore/VoicePrompt.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter VoicePromptTests 2>&1 | grep -E "✘|Test run"`
Expected: `Test run with 8 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/VoicePrompt.swift OdeCore/Tests/OdeCoreTests/VoicePromptTests.swift
git commit -m "feat(core): voice drafting prompt that keeps your words, and a faithfulness check"
```

---

### Task 3: `ode-eval voice`

**Files:**
- Create: `OdeCore/Sources/OdeEval/Voice.swift`
- Modify: `OdeCore/Sources/OdeEval/main.swift` (`usage` at line 8; the command `switch` at the end of the file)

**Interfaces:**
- Consumes: `VoicePrompt`, `VoiceCheck` (Task 2); `local(_:model:system:prompt:schema:)`, `option(_:)`, `fail(_:)`, `decoder`, `unloadLocalModels()` (existing in `main.swift`).
- Produces: `func voice() async throws`, run by `ode-eval voice --model <id|apple> [--base-url …]`.

- [ ] **Step 1: Write the command**

Create `OdeCore/Sources/OdeEval/Voice.swift`:

```swift
import Foundation
import FoundationModels
import OdeCore

/// A fixed, invented suite: no real messages, so drafts can be printed.
struct VoiceCase {
    let them: String
    let context: [(fromMe: Bool, text: String)]
    let request: String
}

let voiceCases: [VoiceCase] = [
    VoiceCase(them: "Maya", context: [(false, "Are you still in for Saturday? Mom's surgery got moved so I might be late")],
              request: "I'm in for Saturday, and ask how her mom's doing"),
    VoiceCase(them: "Sam", context: [(false, "ok be honest. is this place a yes")],
              request: "love the place but the kitchen is tiny, can we see it Thursday"),
    VoiceCase(them: "Dad", context: [(true, "how's the knee"), (false, "Knee's acting up again but I'm fine")],
              request: "check in, ask how the knee is holding up"),
    VoiceCase(them: "Priya", context: [(false, "First day tomorrow!! wish me luck")],
              request: "good luck, you're going to crush it"),
    VoiceCase(them: "Leo", context: [(false, "dinner at 7?")], request: "running ten minutes late, start without me"),
    VoiceCase(them: "Ana", context: [(false, "Did you get the tickets?")], request: "yes got them, two seats in row F"),
    VoiceCase(them: "Mom", context: [(false, "Call me when you can")], request: "um I'm in a meeting, I'll call you after five"),
    VoiceCase(them: "Chris", context: [(false, "Can you help me move Saturday")],
              request: "I can't Saturday, I can do Sunday morning though"),
    VoiceCase(them: "Jess", context: [(false, "I got the job!!!")], request: "that's amazing, so proud of you"),
    VoiceCase(them: "Ben", context: [(true, "you around this weekend?"), (false, "maybe sunday")],
              request: "sounds good, ask what time works"),
]

func voice() async throws {
    guard let model = option("model") else { fail(usage) }
    let baseURL = URL(string: option("base-url") ?? "http://localhost:1234/v1")!
    if model == "apple", !SystemLanguageModel.default.isAvailable { fail("Apple Intelligence is off on this Mac.") }
    if model != "apple" { unloadLocalModels() }
    var faithful = 0
    for (index, item) in voiceCases.enumerated() {
        let messages = item.context.enumerated().map { offset, line in
            Message(id: Int64(offset), guid: "\(offset)", chatID: 1, sender: line.fromMe ? nil : "them", isFromMe: line.fromMe,
                    date: Date(timeIntervalSinceReferenceDate: Double(offset) * 60), text: line.text, textSource: .column, kind: .text)
        }
        let prompt = VoicePrompt.prompt(messages: messages, name: { _ in item.them }, request: item.request, isGroup: false)
        do {
            let text: String
            if model == "apple" {
                let root = DynamicGenerationSchema(name: "VoiceDraft", properties: [
                    .init(name: "text", description: "The message You will send, and nothing else.", schema: .init(type: String.self)),
                ])
                let content = try await LanguageModelSession(instructions: VoicePrompt.instructions)
                    .respond(to: prompt, schema: try GenerationSchema(root: root, dependencies: [])).content
                text = try content.value(String.self, forProperty: "text")
            } else {
                text = try decoder.decode(VoicePrompt.Answer.self, from: try await local(
                    baseURL, model: model, system: VoicePrompt.instructions, prompt: prompt, schema: VoicePrompt.schema)).text
            }
            let problems = VoiceCheck.problems(request: item.request, draft: text)
            if problems.isEmpty { faithful += 1 }
            print("\(index + 1). \(item.request)\n   -> \(text)\n   \(problems.isEmpty ? "ok" : "\(problems)")")
        } catch {
            print("\(index + 1). failed: \(error)")
        }
    }
    print("\nFaithful: \(faithful)/\(voiceCases.count)")
}
```

- [ ] **Step 2: Wire the command and usage**

In `OdeCore/Sources/OdeEval/main.swift`, add to `usage` before the closing `"""`:

```
    ode-eval voice --model <id|apple> [--base-url http://localhost:1234/v1]
        Turn invented spoken requests into messages and check nothing was added or dropped.
```

and add a case to the final `switch`:

```swift
case "voice": try await voice()
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path OdeCore --product ode-eval 2>&1 | grep -E "error:|Compiling|Build complete" | tail -2`
Expected: `Build complete!`

- [ ] **Step 4: Run it**

Run with LM Studio's current model if it's running (`curl -s localhost:1234/v1/models` lists it), otherwise with Apple's:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --package-path OdeCore ode-eval voice --model apple 2>&1 | tail -15`
Expected: ten numbered cases and a `Faithful: N/10` line. Record N in the commit message; there's no pass bar yet, this is the baseline plan 2b's prompt work is measured against. If neither model is available, say so and skip.

- [ ] **Step 5: Run the whole suite and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore 2>&1 | tail -1`
Expected: all tests pass.

```bash
git add OdeCore/Sources/OdeEval/Voice.swift OdeCore/Sources/OdeEval/main.swift
git commit -m "feat(eval): measure how faithfully a model keeps your spoken words"
```
