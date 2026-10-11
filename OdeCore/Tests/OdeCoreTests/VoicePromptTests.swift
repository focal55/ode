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
