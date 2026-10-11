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

    @Test func spokenQuestionsNeedNoQuestionMark() {
        #expect(VoiceCheck.problems(request: "love the place, can we see it Thursday",
                                    draft: "Love the place. Can we see it Thursday?").isEmpty)
    }

    @Test func aQuestionWordMidSentenceDoesNotExcuseAnAddedQuestion() {
        #expect(VoiceCheck.problems(request: "I can do Sunday", draft: "I can do Sunday, want to grab lunch?")
                .contains(.addedQuestion))
    }

    @Test func checkInIsAnInstructionNotContent() {
        #expect(VoiceCheck.problems(request: "check in, ask how the knee is", draft: "How's the knee?").isEmpty)
    }

    @Test(arguments: [("see you at seven thirty", "See you at 7:30"), ("twenty five minutes out", "25 min out"),
                      ("I'll call you after five", "I'll call you after 5:00")])
    func spokenTimesAndQuantitiesMatchDigits(_ request: String, _ draft: String) {
        #expect(VoiceCheck.problems(request: request, draft: draft).isEmpty)
    }

    @Test func aChangedNumberInsideATokenIsFlagged() {
        #expect(VoiceCheck.problems(request: "I'll call you after five", draft: "I'll call you after 6pm") == [.addedNumber("6")])
    }

    @Test func casualAbbreviationsAreNotDropped() {
        #expect(VoiceCheck.problems(request: "going to be there tomorrow, sending the photos",
                                    draft: "gonna be there tmrw, sending the pics").isEmpty)
    }

    @Test(arguments: [("hows the knee", "How's the knee?"),
                      ("its at 7 and do you want me to pick you up", "It's at 7, do you want me to pick you up?"),
                      ("check in", "How are you doing?")])
    func spokenQuestionsInAnyShapeAreAllowed(_ request: String, _ draft: String) {
        #expect(VoiceCheck.problems(request: request, draft: draft).isEmpty)
    }

    @Test(arguments: [("I'm in. ask what time", "I'm in! What time? Should I bring anything?"),
                      ("I'll call you when I land", "I'll call you when I land, how was your day?")])
    func aQuestionBeyondWhatYouAskedIsFlagged(_ request: String, _ draft: String) {
        #expect(VoiceCheck.problems(request: request, draft: draft).contains(.addedQuestion))
    }

    @Test func aDroppedNegationIsFlagged() {
        #expect(VoiceCheck.problems(request: "I'm not coming tonight", draft: "I'm coming tonight") == [.droppedNegation])
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

    @Test func revisionCarriesTheDraftAndTheChange() {
        let prompt = VoicePrompt.revision(messages: [], name: { _ in "Maya" }, draft: "I'm in for Saturday!",
                                          instruction: "make it shorter", isGroup: false)
        #expect(prompt.contains("Your draft: I'm in for Saturday!"))
        #expect(prompt.hasSuffix("Change You asked for: make it shorter"))
    }

    @Test func copiedReportedSpeechIsFlagged() {
        #expect(VoiceCheck.problems(request: "ask how her mom's doing", draft: "How is her mom doing?") == [.reportedSpeech])
        #expect(VoiceCheck.problems(request: "ask how her mom's doing", draft: "How's your mom doing?").isEmpty)
    }
}
