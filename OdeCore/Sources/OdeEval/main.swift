import Foundation
import FoundationModels
import OdeCore

// Measures how close drafted replies come to what you actually sent. Prints only scores; the
// side-by-side report with message text is written next to Ode's data, never to the terminal.

let usage = """
    ode-eval build [--count 30] [--chats 12,34]
        Freeze a test set of real replies from the conversations chosen in Ode (or --chats).
    ode-eval run --model <id|apple> [--judge qwen/qwen3.6-27b] [--length balanced] [--label name]
                 [--base-url http://localhost:1234/v1] [--limit N]
        Draft each reply with a model, have the judge score the drafts against what you sent.
    ode-eval review [--count 20] [--models qwen/qwen3.6-27b,apple]
        Blind pairs: pick the set of drafts you'd rather reply from. Uses each model's latest run.
    ode-eval summary
        Compare every run so far, and your blind picks.
    """

let folder = ProcessInfo.processInfo.environment["ODE_EVAL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ode/eval", isDirectory: true)
let setURL = folder.appendingPathComponent("moments.json")
let runsFolder = folder.appendingPathComponent("runs", isDirectory: true)

struct StoredMessage: Codable {
    let fromMe: Bool
    let speaker: String
    let text: String
    let date: Date
}

struct StoredMoment: Codable {
    let id: String
    let chatID: Int64
    let isGroup: Bool
    let context: [StoredMessage]
    let actual: String
}

struct Option: Codable {
    let label: String
    let text: String
    let why: String
}

struct MomentResult: Codable {
    let id: String
    var drafts: [Option] = []
    var scores: [Int] = []
    var note = ""
    var bestScore = 0
    var bestStyle = 0.0
    var actualStyle = 0.0
    var seconds = 0.0
    var error: String?
}

struct Run: Codable {
    let label: String
    let model: String
    let judge: String
    let length: String
    let date: Date
    var results: [MomentResult]
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

// MARK: - Build

func build() throws {
    let store: MessagesStore
    do { store = try MessagesStore() } catch { fail("Can't read Messages: \(error). Grant your terminal Full Disk Access.") }
    let chats = try store.chats()
    let chosen: Set<Int64> = if let list = option("chats") {
        Set(list.split(separator: ",").compactMap { Int64($0) })
    } else if let saved = UserDefaults(suiteName: "com.focal55.ode")?.array(forKey: "selectedChatIDs") as? [Int], !saved.isEmpty {
        Set(saved.map(Int64.init))
    } else {
        Set(chats.filter { !$0.isGroup }.sorted { $0.messageCount > $1.messageCount }.prefix(15).map(\.id))
    }
    let count = option("count").flatMap(Int.init) ?? 30
    let since = Date.now.addingTimeInterval(-2 * 365 * 86_400)

    var byChat: [[ReplyMoment]] = []
    var groups: [Int64: Bool] = [:]
    for chat in chats where chosen.contains(chat.id) {
        groups[chat.id] = chat.isGroup
        let moments = ReplyMoments.find(in: try store.messages(chatID: chat.id, limit: 5000)).filter { $0.actual.date > since }
        if !moments.isEmpty { byChat.append(moments) }
    }
    let sample = ReplyMoments.sample(byChat, count: count)
    let stored = sample.map { moment -> StoredMoment in
        let isGroup = groups[moment.actual.chatID] ?? false
        var people: [String: String] = [:]
        let context = moment.context.map { message -> StoredMessage in
            let speaker: String
            if message.isFromMe {
                speaker = "You"
            } else if isGroup {
                let handle = message.sender ?? "?"
                speaker = people[handle] ?? "Person \(people.count + 1)"
                people[handle] = speaker
            } else {
                speaker = "Them"
            }
            return StoredMessage(fromMe: message.isFromMe, speaker: speaker, text: message.text ?? "", date: message.date)
        }
        return StoredMoment(id: moment.actual.guid, chatID: moment.actual.chatID, isGroup: isGroup, context: context,
                            actual: moment.actual.text ?? "")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try encoder.encode(stored).write(to: setURL, options: .atomic)
    print("Froze \(stored.count) replies from \(Set(stored.map(\.chatID)).count) conversations (\(chosen.count) chosen).")
    print("Saved to \(setURL.path)")
}

// MARK: - Models

func messages(of moment: StoredMoment) -> [Message] {
    moment.context.enumerated().map { index, stored in
        Message(id: Int64(index), guid: "\(moment.id)-\(index)", chatID: moment.chatID, sender: stored.fromMe ? nil : stored.speaker,
                isFromMe: stored.fromMe, date: stored.date, text: stored.text, textSource: .column, kind: .text)
    }
}

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 600
    return URLSession(configuration: configuration)
}()

/// One structured answer from an OpenAI-compatible server such as LM Studio.
func local(_ baseURL: URL, model: String, system: String, prompt: String, schema: [String: Any]) async throws -> Data {
    let body: [String: Any] = [
        "model": model,
        "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        "response_format": ["type": "json_schema", "json_schema": ["name": "answer", "strict": true, "schema": schema]],
    ]
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw EvalError.http(status) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
    let content = (message?["content"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    guard let text = content ?? message?["reasoning_content"] as? String else { throw EvalError.empty }
    return Data(text.utf8)
}

/// LM Studio keeps every model it loads, and refuses the next one once memory is full, so
/// each phase starts with nothing loaded and lets the request load what it needs.
func unloadLocalModels() {
    let lms = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms")
    guard FileManager.default.isExecutableFile(atPath: lms.path) else { return }
    let process = Process()
    process.executableURL = lms
    process.arguments = ["unload", "--all"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

enum EvalError: Error {
    case http(Int)
    case empty
}

/// Apple's on-device model, given the same guides as the app's @Generable types without the macros.
func apple(prompt: String) async throws -> [Option] {
    let option = DynamicGenerationSchema(name: "DraftOption", properties: [
        .init(name: "text", description: "The complete message You could send as-is.", schema: .init(type: String.self)),
        .init(name: "why", description: "Under eight words on why this works, for example 'Closes the photos loop' or 'Matches her tone'.",
              schema: .init(type: String.self)),
    ])
    let root = DynamicGenerationSchema(name: "ReplyDrafts", properties: [
        .init(name: "direct", description: "A direct reply that answers the latest message.", schema: .init(referenceTo: "DraftOption")),
        .init(name: "warm", description: "A warm reply that answers the latest message and shows interest in them.",
              schema: .init(referenceTo: "DraftOption")),
        .init(name: "playful", description: "A reply with light humor that still answers the latest message.",
              schema: .init(referenceTo: "DraftOption")),
    ])
    let schema = try GenerationSchema(root: root, dependencies: [option])
    let content = try await LanguageModelSession(instructions: ReplyPrompt.instructions).respond(to: prompt, schema: schema).content
    return try ["direct", "warm", "playful"].map { name in
        let draft = try content.value(GeneratedContent.self, forProperty: name)
        return Option(label: name.uppercased(), text: try draft.value(String.self, forProperty: "text"),
                      why: try draft.value(String.self, forProperty: "why"))
    }
}

// MARK: - Judging

let judgeInstructions = """
    You grade drafted text messages against the reply a person actually sent. Judge whether sending the draft \
    would have done the same job: answered the same thing, with the same intent and the same decision (yes or no, \
    the same plan, the same information). Wording and tone do not matter here. Score each draft from 1 to 5: \
    5 does the same job, 4 does the job with a small difference, 3 is plausible but takes a different decision or \
    misses a key point, 2 is mostly off, 1 is wrong, off-topic, or invents facts that are not in the conversation.
    """

func judgeSchema() -> [String: Any] {
    let score: [String: Any] = ["type": "integer", "enum": [1, 2, 3, 4, 5]]
    return [
        "type": "object",
        "properties": ["direct": score, "warm": score, "playful": score,
                       "note": ["type": "string", "description": "One short sentence on what the best draft got right or missed."]],
        "required": ["direct", "note", "playful", "warm"],
        "additionalProperties": false,
    ]
}

struct Verdict: Decodable {
    let direct: Int
    let warm: Int
    let playful: Int
    let note: String
}

func judgePrompt(_ moment: StoredMoment, _ drafts: [Option]) -> String {
    var lines = ["Conversation:"]
    lines += moment.context.suffix(12).map { "\($0.speaker): \($0.text.prefix(280))" }
    lines += ["", "What You actually sent: \(moment.actual)", "", "Drafts:"]
    lines += drafts.map { "\($0.label.lowercased()): \($0.text)" }
    return lines.joined(separator: "\n")
}

// MARK: - Run

func run() async throws {
    guard let model = option("model") else { fail(usage) }
    guard let data = try? Data(contentsOf: setURL) else { fail("No test set yet. Run `ode-eval build` first.") }
    var moments = try decoder.decode([StoredMoment].self, from: data)
    if let limit = option("limit").flatMap(Int.init) { moments = Array(moments.prefix(limit)) }
    let judge = option("judge") ?? "qwen/qwen3.6-27b"
    let baseURL = URL(string: option("base-url") ?? "http://localhost:1234/v1")!
    let length = DraftLength.allCases.first { $0.rawValue.lowercased() == (option("length") ?? "balanced").lowercased() } ?? .balanced
    let label = option("label") ?? "\(model.split(separator: "/").last ?? "")-\(length.rawValue.lowercased())"
    if model == "apple", !SystemLanguageModel.default.isAvailable { fail("Apple Intelligence is off on this Mac.") }

    var current = Run(label: label, model: model, judge: judge, length: length.rawValue, date: .now, results: [])
    print("\(label): \(moments.count) replies, drafting with \(model), judged by \(judge)")
    // Draft everything, then judge everything, so LM Studio isn't swapping two models per reply.
    print("Drafting")
    unloadLocalModels()
    for (index, moment) in moments.enumerated() {
        let context = messages(of: moment)
        var result = MomentResult(id: moment.id)
        result.actualStyle = WritingStyle(of: context).match(moment.actual)
        let prompt = ReplyPrompt.prompt(messages: context, name: { $0 ?? "You" }, openLoops: [], steer: "",
                                        length: length, isGroup: moment.isGroup)
        let started = Date()
        do {
            if model == "apple" {
                result.drafts = try await apple(prompt: prompt)
            } else {
                let answer = try decoder.decode(ReplyDraftsJSON.self, from: try await local(
                    baseURL, model: model, system: ReplyPrompt.instructions, prompt: prompt, schema: ReplyPrompt.schema))
                result.drafts = [Option(label: "DIRECT", text: answer.direct.text, why: answer.direct.why),
                                 Option(label: "WARM", text: answer.warm.text, why: answer.warm.why),
                                 Option(label: "PLAYFUL", text: answer.playful.text, why: answer.playful.why)]
            }
            result.seconds = Date().timeIntervalSince(started)
            print(String(format: "  %2d/%d  %.1fs", index + 1, moments.count, result.seconds))
        } catch {
            result.error = "draft: \(error)"
            print("  \(index + 1)/\(moments.count)  failed: \(error)")
        }
        current.results.append(result)
    }

    print("Judging")
    unloadLocalModels()
    for (index, moment) in moments.enumerated() where current.results[index].error == nil {
        var result = current.results[index]
        do {
            let verdict = try decoder.decode(Verdict.self, from: try await local(
                baseURL, model: judge, system: judgeInstructions, prompt: judgePrompt(moment, result.drafts), schema: judgeSchema()))
            result.scores = [verdict.direct, verdict.warm, verdict.playful]
            result.note = verdict.note
            let style = WritingStyle(of: messages(of: moment))
            let styles = result.drafts.map { style.match($0.text) }
            let best = result.scores.indices.max { (result.scores[$0], styles[$0]) < (result.scores[$1], styles[$1]) }!
            result.bestScore = result.scores[best]
            result.bestStyle = styles[best]
            print(String(format: "  %2d/%d  best %d  style %.2f  (yours %.2f)", index + 1, moments.count,
                         result.bestScore, result.bestStyle, result.actualStyle))
        } catch {
            result.error = "judge: \(error)"
            print("  \(index + 1)/\(moments.count)  failed: \(error)")
        }
        current.results[index] = result
    }

    try FileManager.default.createDirectory(at: runsFolder, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: current.date).replacingOccurrences(of: ":", with: "")
    let base = runsFolder.appendingPathComponent("\(stamp)-\(label.replacingOccurrences(of: "/", with: "-"))")
    try encoder.encode(current).write(to: base.appendingPathExtension("json"), options: .atomic)
    try report(current, moments).write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
    print("")
    printTable([current])
    print("\nReport with the drafts beside what you sent: \(base.appendingPathExtension("md").path)")
}

func report(_ run: Run, _ moments: [StoredMoment]) -> String {
    let byID = Dictionary(moments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var lines = ["# \(run.label)", "", "Drafted by \(run.model), judged by \(run.judge), \(run.length).", ""]
    for (index, result) in run.results.enumerated() {
        guard let moment = byID[result.id] else { continue }
        lines += ["## \(index + 1). best \(result.bestScore)/5", ""]
        lines += moment.context.suffix(4).map { "> **\($0.speaker):** \($0.text)" }
        lines += ["", "**You sent:** \(moment.actual)", ""]
        if let error = result.error { lines += ["Failed: \(error)", ""]; continue }
        for (draft, score) in zip(result.drafts, result.scores) {
            lines.append("- \(score)/5 *\(draft.label.lowercased())*: \(draft.text)")
        }
        lines += ["", "_\(result.note)_", ""]
    }
    return lines.joined(separator: "\n")
}

// MARK: - Summary

/// A refused or broken draft counts as a miss (score 1); a judge failure isn't the drafter's fault and is left out.
func printTable(_ runs: [Run]) {
    print("run".padding(toLength: 28, withPad: " ", startingAt: 0) + "  n  refused  best/5  hit≥4   style  yours  median s")
    for run in runs {
        let scored = run.results.filter { $0.error?.hasPrefix("judge:") != true }
        let drafted = scored.filter { $0.error == nil }
        let best = scored.map { $0.error == nil ? Double($0.bestScore) : 1 }
        let mean = { (values: [Double]) in values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        let seconds = drafted.map(\.seconds).sorted()
        print(String(format: "%@  %2d  %7d   %5.2f   %4.0f%%   %5.2f  %5.2f  %7.1f",
                     run.label.padding(toLength: 28, withPad: " ", startingAt: 0), scored.count, scored.count - drafted.count,
                     mean(best), best.isEmpty ? 0 : Double(best.filter { $0 >= 4 }.count) / Double(best.count) * 100,
                     mean(drafted.map(\.bestStyle)), mean(drafted.map(\.actualStyle)), seconds.isEmpty ? 0 : seconds[seconds.count / 2]))
    }
}

func loadRuns() -> [Run] {
    let files = (try? FileManager.default.contentsOfDirectory(at: runsFolder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        .compactMap { try? decoder.decode(Run.self, from: Data(contentsOf: $0)) }
}

func summary() throws {
    let runs = loadRuns()
    guard !runs.isEmpty else { fail("No runs yet.") }
    printTable(runs)
    let picks = loadPicks()
    if !picks.isEmpty {
        print("")
        printPicks(picks)
    }
}

// MARK: - Review

struct Pick: Codable {
    let moment: String
    let left: String
    let right: String
    /// "left", "right", "both" (either would do) or "neither".
    let choice: String
    let date: Date
}

let picksURL = folder.appendingPathComponent("picks.json")

func loadPicks() -> [Pick] {
    (try? Data(contentsOf: picksURL)).flatMap { try? decoder.decode([Pick].self, from: $0) } ?? []
}

func pairKey(_ moment: String, _ first: String, _ second: String) -> String {
    ([moment] + [first, second].sorted()).joined(separator: "|")
}

func review() throws {
    guard let data = try? Data(contentsOf: setURL) else { fail("No test set yet. Run `ode-eval build` first.") }
    let moments = Dictionary(try decoder.decode([StoredMoment].self, from: data).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var latest: [String: Run] = [:]
    for run in loadRuns() { latest[run.model] = run }
    if let list = option("models") {
        let wanted = Set(list.split(separator: ",").map(String.init))
        latest = latest.filter { wanted.contains($0.key) }
    }
    guard latest.count >= 2 else { fail("Need runs from at least two models. Have: \(latest.keys.sorted().joined(separator: ", "))") }
    let drafts = latest.mapValues { run in
        Dictionary(run.results.filter { $0.error == nil && !$0.drafts.isEmpty }.map { ($0.id, $0.drafts) }, uniquingKeysWith: { first, _ in first })
    }

    var picks = loadPicks()
    let done = Set(picks.map { pairKey($0.moment, $0.left, $0.right) })
    let models = latest.keys.sorted()
    // Every pair of models takes turns, so a short session still compares each pair.
    var queues: [[(moment: String, first: String, second: String)]] = []
    for (index, first) in models.enumerated() {
        for second in models[(index + 1)...] {
            queues.append(moments.keys.filter { id in
                drafts[first]?[id] != nil && drafts[second]?[id] != nil && !done.contains(pairKey(id, first, second))
            }.shuffled().map { ($0, first, second) })
        }
    }
    queues.shuffle()
    let count = option("count").flatMap(Int.init) ?? 20
    var todo: [(moment: String, first: String, second: String)] = []
    var round = 0
    while todo.count < count, queues.contains(where: { round < $0.count }) {
        for queue in queues where round < queue.count && todo.count < count { todo.append(queue[round]) }
        round += 1
    }
    guard !todo.isEmpty else { fail("You've reviewed every pair these runs can make. Do a new run to review more.") }

    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"
    for (index, item) in todo.enumerated() {
        let moment = moments[item.moment]!
        let (left, right) = Bool.random() ? (item.first, item.second) : (item.second, item.first)
        print("\u{1B}[2J\u{1B}[H\(dim)\(index + 1) of \(todo.count)\(reset)\n")
        for message in moment.context.suffix(8) {
            print(message.fromMe ? "  \(bold)You:\(reset) \(message.text)" : "  \(dim)\(message.speaker):\(reset) \(message.text)")
        }
        for (name, model) in [("A", left), ("B", right)] {
            print("\n\(bold)\(name)\(reset)")
            for draft in drafts[model]![item.moment]! { print("  - \(draft.text)") }
        }
        print("\nWhich set would you rather pick your reply from?")
        var choice: String?
        while choice == nil {
            print("[a] A   [b] B   [=] either is fine   [n] neither   [s] skip   [q] quit: ", terminator: "")
            guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { choice = "q"; break }
            choice = ["a": "left", "b": "right", "=": "both", "n": "neither", "s": "s", "q": "q"][line]
        }
        if choice == "q" { break }
        if choice == "s" { continue }
        picks.append(Pick(moment: item.moment, left: left, right: right, choice: choice!, date: .now))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(picks).write(to: picksURL, options: .atomic)
    }
    print("\u{1B}[2J\u{1B}[H")
    printPicks(picks)
}

/// "Won" counts sets you picked over the other; "fine" adds the times either would do, so it
/// reads as how often that model gave you something you'd send.
func printPicks(_ picks: [Pick]) {
    print("Your blind picks (\(picks.count))")
    let models = Set(picks.flatMap { [$0.left, $0.right] }).sorted()
    print("model".padding(toLength: 28, withPad: " ", startingAt: 0) + "  seen  won  lost  either  neither  win rate  fine")
    for model in models {
        let seen = picks.filter { $0.left == model || $0.right == model }
        let won = seen.filter { ($0.choice == "left" && $0.left == model) || ($0.choice == "right" && $0.right == model) }.count
        let either = seen.filter { $0.choice == "both" }.count
        let neither = seen.filter { $0.choice == "neither" }.count
        let lost = seen.count - won - either - neither
        let rate = (Double(won) + Double(either + neither) / 2) / Double(seen.count) * 100
        let fine = Double(won + either) / Double(seen.count) * 100
        print(String(format: "%@  %4d  %3d  %4d  %6d  %7d  %7.0f%%  %3.0f%%", model.padding(toLength: 28, withPad: " ", startingAt: 0),
                     seen.count, won, lost, either, neither, rate, fine))
    }
    print("\nHead to head")
    for (index, first) in models.enumerated() {
        for second in models[(index + 1)...] {
            let pair = picks.filter { Set([$0.left, $0.right]) == Set([first, second]) }
            guard !pair.isEmpty else { continue }
            let firstWins = pair.filter { ($0.choice == "left" && $0.left == first) || ($0.choice == "right" && $0.right == first) }.count
            let secondWins = pair.filter { ($0.choice == "left" && $0.left == second) || ($0.choice == "right" && $0.right == second) }.count
            print("  \(first) \(firstWins), \(second) \(secondWins)  (either \(pair.filter { $0.choice == "both" }.count), neither \(pair.filter { $0.choice == "neither" }.count))")
        }
    }
}

switch CommandLine.arguments.dropFirst().first {
case "build": try build()
case "run": try await run()
case "review": try review()
case "summary": try summary()
default: print(usage)
}
