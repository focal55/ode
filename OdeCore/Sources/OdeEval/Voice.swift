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
