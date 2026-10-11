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
