import Foundation
import FoundationModels
import OdeCore

@Generable
struct DraftOption {
    @Guide(description: "The complete message You could send as-is.")
    var text: String

    @Guide(description: "Under eight words on why this works, for example 'Closes the photos loop' or 'Matches her tone'.")
    var why: String
}

@Generable
struct ReplyDrafts {
    @Guide(description: "A direct reply that answers the latest message.")
    var direct: DraftOption

    @Guide(description: "A warm reply that answers the latest message and shows interest in them.")
    var warm: DraftOption

    @Guide(description: "A reply with light humor that still answers the latest message.")
    var playful: DraftOption
}

struct Draft: Identifiable, Equatable {
    let label: String
    let text: String
    let why: String
    var id: String { label }
}

enum DraftResult: Equatable {
    /// `onDevice` is true when Apple's model wrote them, including when the chosen model didn't answer.
    case drafts([Draft], onDevice: Bool)
    case unavailable
    case blocked
}

/// Drafts replies on device. Nothing is sent; the user copies or opens Messages. Returns nil
/// only when the task was cancelled.
enum ReplyDrafter {
    static func draft(messages: [Message], name: (String?) -> String, openLoops: [String], steer: String,
                      length: DraftLength, isGroup: Bool, avoid: [String] = [], cloud: CloudRunner? = nil) async -> DraftResult? {
        let prompt = ReplyPrompt.prompt(messages: messages, name: name, openLoops: openLoops, steer: steer,
                                        length: length, isGroup: isGroup, avoid: avoid)

        if let cloud, let data = await cloud(CloudRequest(system: ReplyPrompt.instructions, prompt: prompt, schemaName: "drafts",
                                                          schema: ReplyPrompt.schema, effort: "medium")),
           let drafts = try? JSONDecoder().decode(ReplyDraftsJSON.self, from: data) {
            return .drafts([
                Draft(label: "DIRECT", text: drafts.direct.text, why: drafts.direct.why),
                Draft(label: "WARM", text: drafts.warm.text, why: drafts.warm.why),
                Draft(label: "PLAYFUL", text: drafts.playful.text, why: drafts.playful.why),
            ], onDevice: false)
        }
        // A stopped cloud call fails like any other; don't spend the on-device model on it.
        guard !Task.isCancelled else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return .unavailable }
        for _ in 0..<2 {
            let session = LanguageModelSession(instructions: ReplyPrompt.instructions)
            guard !Task.isCancelled else { return nil }
            if let drafts = try? await session.respond(to: prompt, generating: ReplyDrafts.self).content {
                return .drafts([
                    Draft(label: "DIRECT", text: drafts.direct.text, why: drafts.direct.why),
                    Draft(label: "WARM", text: drafts.warm.text, why: drafts.warm.why),
                    Draft(label: "PLAYFUL", text: drafts.playful.text, why: drafts.playful.why),
                ], onDevice: true)
            }
        }
        return .blocked
    }
}
