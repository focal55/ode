import Foundation
import FoundationModels
import OdeCore

@Generable
struct VoiceDraft {
    @Guide(description: "The message You will send, and nothing else.")
    var text: String
}

/// Your spoken words as the message you'd send, through the drafting model, falling back to Apple's.
enum VoiceDrafter {
    static let label = "YOUR WORDS"

    static func draft(instructions: String, prompt: String, cloud: CloudRunner?) async -> DraftResult? {
        if let cloud, let data = await cloud(CloudRequest(system: instructions, prompt: prompt, schemaName: "voice",
                                                          schema: VoicePrompt.schema)),
           let answer = try? JSONDecoder().decode(VoicePrompt.Answer.self, from: data) {
            return .drafts([Draft(label: label, text: answer.text, why: "From what you said")], onDevice: false)
        }
        guard !Task.isCancelled else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return .unavailable }
        let session = LanguageModelSession(instructions: instructions)
        guard let answer = try? await session.respond(to: prompt, generating: VoiceDraft.self).content else {
            return Task.isCancelled ? nil : .blocked
        }
        return .drafts([Draft(label: label, text: answer.text, why: "From what you said")], onDevice: true)
    }
}
