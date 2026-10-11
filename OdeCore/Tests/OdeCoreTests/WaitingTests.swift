import Foundation
import Testing
@testable import OdeCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

private func w(_ id: Int64, me: Bool, _ text: String?, hoursAgo: Double, kind: Message.Kind = .text,
               source: Message.TextSource = .column) -> Message {
    Message(id: id, guid: "g\(id)", chatID: 7, sender: me ? nil : "+15550001111", isFromMe: me,
            date: now.addingTimeInterval(-hoursAgo * hour), text: text, textSource: source, kind: kind)
}

/// How MessagesStore shapes a message it couldn't decode: no text, no attachment.
private func undecodable(_ id: Int64, me: Bool, hoursAgo: Double) -> Message {
    w(id, me: me, nil, hoursAgo: hoursAgo, kind: .other, source: .undecodable)
}

private func conversation(group: Bool = false) -> Conversation {
    Conversation(chats: [Chat(id: 7, identifier: "x", displayName: nil, isGroup: group,
                              participants: group ? ["+15550001111", "+15550002222"] : ["+15550001111"],
                              messageCount: 0, lastMessageDate: nil)])
}

@Suite struct UnansweredTests {
    func find(_ messages: [Message], group: Bool = false) -> Waiting? {
        Waiting.unanswered(in: conversation(group: group), messages: messages, now: now)
    }

    @Test func theirMessageAfterYoursIsWaiting() {
        let item = find([w(1, me: true, "how was the trip", hoursAgo: 30), w(2, me: false, "amazing, sending pics soon", hoursAgo: 5)])
        #expect(item?.kind == .unanswered)
        #expect(item?.text == "amazing, sending pics soon")
        #expect(item?.steer == "reply to their last message")
        #expect(item?.since == now.addingTimeInterval(-5 * hour))
        #expect(item?.newestMessageID == 2)
        #expect(item?.conversationID == 7)
    }

    @Test func aQuestionIsAsked() {
        let item = find([w(1, me: true, "hey", hoursAgo: 30), w(2, me: false, "are you free Saturday?", hoursAgo: 4)])
        #expect(item?.kind == .asked)
        #expect(item?.steer == "answer their question")
    }

    @Test func yourReplyClearsIt() {
        #expect(find([w(1, me: false, "are you free Saturday?", hoursAgo: 6), w(2, me: true, "yes!", hoursAgo: 5)]) == nil)
    }

    @Test func yourReactionClearsIt() {
        #expect(find([w(1, me: false, "landed safe", hoursAgo: 6),
                      w(2, me: true, "Loved “landed safe”", hoursAgo: 5, kind: .reaction)]) == nil)
    }

    @Test func theirReactionIsNotAMessage() {
        #expect(find([w(1, me: true, "see you then", hoursAgo: 6),
                      w(2, me: false, "Liked “see you then”", hoursAgo: 5, kind: .reaction)]) == nil)
    }

    @Test func tooRecentIsNotWaitingYet() {
        #expect(find([w(1, me: false, "are you free Saturday?", hoursAgo: 0.5)]) == nil)
    }

    @Test func olderThanThreeWeeksIsLeftToGoneQuiet() {
        #expect(find([w(1, me: false, "are you free Saturday?", hoursAgo: 22 * 24)]) == nil)
    }

    @Test func windowEdgesAreIncluded() {
        #expect(find([w(1, me: false, "call me", hoursAgo: 1)]) != nil)
        #expect(find([w(1, me: false, "call me", hoursAgo: 21 * 24)]) != nil)
    }

    @Test func windowUsesTheirLatestMessage() {
        #expect(find([w(1, me: false, "dinner friday?", hoursAgo: 30), w(2, me: false, "also call me", hoursAgo: 0.2)]) == nil)
    }

    @Test(arguments: ["ok", "Okay.", "thanks!!", "Thank you 🙏", "lol 😂", "sounds good", "Got it", "👍", "❤️", "kk", "you too!",
                      "👍🏻", "👍🏽", "❤", "♥️", "ok 👍🏾"])
    func closersAreNotWaiting(_ text: String) {
        #expect(find([w(1, me: true, "see you at 7", hoursAgo: 6), w(2, me: false, text, hoursAgo: 5)]) == nil)
    }

    @Test(arguments: ["K, talk soon", "Ok, love you", "talk soon!", "Night!", "ok and thanks", "Sounds good. Love you ❤️",
                      "bye, see you soon", "No worries!"])
    func signOffsAreNotWaiting(_ text: String) {
        #expect(find([w(1, me: true, "see you at 7", hoursAgo: 6), w(2, me: false, text, hoursAgo: 5)]) == nil)
    }

    @Test(arguments: ["Sounds good, see you at 7", "Thanks! Can you send the photos", "ok, call me tomorrow"])
    func signOffsWithMoreStillCount(_ text: String) {
        #expect(find([w(1, me: true, "see you at 7", hoursAgo: 6), w(2, me: false, text, hoursAgo: 5)]) != nil)
    }

    @Test(arguments: ["ok?", "ok but when", "thanks for the help, how much do I owe you", "lol what"])
    func nearClosersStillCount(_ text: String) {
        #expect(find([w(1, me: true, "see you at 7", hoursAgo: 6), w(2, me: false, text, hoursAgo: 5)]) != nil)
    }

    @Test func aLaterCloserDoesNotHideAnEarlierQuestion() {
        let item = find([w(1, me: true, "hey", hoursAgo: 30), w(2, me: false, "can you send the address?", hoursAgo: 8),
                         w(3, me: false, "lol", hoursAgo: 7)])
        #expect(item?.kind == .asked)
        #expect(item?.text == "can you send the address?")
        #expect(item?.since == now.addingTimeInterval(-8 * hour))
        #expect(item?.newestMessageID == 3)
    }

    @Test func onlyClosersMeansNothingIsWaiting() {
        #expect(find([w(1, me: true, "done", hoursAgo: 9), w(2, me: false, "thanks", hoursAgo: 8),
                      w(3, me: false, "👍", hoursAgo: 7)]) == nil)
    }

    @Test func neverRepliedStillCounts() {
        #expect(find([w(1, me: false, "hi it's Sam from the climbing gym", hoursAgo: 3)])?.kind == .unanswered)
    }

    @Test func attachmentsAndUndecodedTextGetALabel() {
        #expect(find([w(1, me: false, nil, hoursAgo: 3, kind: .attachmentOnly)])?.text == "Attachment")
        #expect(find([undecodable(1, me: false, hoursAgo: 3)])?.text == "Message")
    }

    @Test func photoPlaceholdersAreNotShownAsText() {
        #expect(find([w(1, me: false, "\u{FFFC}", hoursAgo: 3)])?.text == "Attachment")
        #expect(find([w(1, me: false, "\u{FFFC}Look at this view", hoursAgo: 3)])?.text == "Look at this view")
    }

    @Test func yourUndecodableReplyStillAnswers() {
        #expect(find([w(1, me: false, "are you free Saturday?", hoursAgo: 6), undecodable(2, me: true, hoursAgo: 5)]) == nil)
    }

    @Test func onlyTheirRecentMessagesCountWhenYouNeverReplied() {
        let item = find([w(1, me: false, "how are you?", hoursAgo: 3 * 365 * 24), w(2, me: false, "on my way to the lake", hoursAgo: 5)])
        #expect(item?.kind == .unanswered)
        #expect(item?.since == now.addingTimeInterval(-5 * hour))
    }

    @Test func theirTapbackDoesNotMoveTheNewestMessage() {
        let item = find([w(1, me: true, "hey", hoursAgo: 30), w(2, me: false, "free Saturday?", hoursAgo: 6),
                         w(3, me: false, "Loved “hey”", hoursAgo: 5, kind: .reaction)])
        #expect(item?.newestMessageID == 2)
    }

    @Test func newestSpokenIDIgnoresReactions() {
        #expect(Waiting.newestSpokenID(in: [w(1, me: false, "free Saturday?", hoursAgo: 6),
                                             w(2, me: false, "Loved “hey”", hoursAgo: 5, kind: .reaction)]) == 1)
        #expect(Waiting.newestSpokenID(in: []) == 0)
    }

    @Test func groupsAreLeftOut() {
        #expect(find([w(1, me: false, "anyone free Saturday?", hoursAgo: 3)], group: true) == nil)
    }

    @Test func emptyThreadIsNothing() {
        #expect(find([]) == nil)
    }
}

@Suite struct WaitingKindsTests {
    func metrics(lastLongDaysAgo: Double, usualGapDays: Double) -> RelationshipMetrics {
        RelationshipMetrics(
            messageCount: 100, conversations: 10, youStartShare: 0.5, yourMedianReply: 600, theirMedianReply: 600,
            yourRecentMedianReply: 600, lastLongConversation: now.addingTimeInterval(-lastLongDaysAgo * day),
            usualGapBetweenLongConversations: usualGapDays * day, weekly: [])
    }

    @Test func promiseReadsAsWhatYouSaid() {
        let item = Waiting.promised(in: conversation(), task: "Send the Big Sur photos", made: now, newestMessageID: 40)
        #expect(item.kind == .promised)
        #expect(item.text == "You said you'd send the Big Sur photos")
        #expect(item.steer == "follow up on: send the Big Sur photos")
        #expect(item.since == now)
        #expect(item.newestMessageID == 40)
        #expect(item.conversationID == 7)
    }

    @Test func goneQuietUsesTheOverdueObservation() {
        let item = Waiting.quiet(in: conversation(), metrics: metrics(lastLongDaysAgo: 35, usualGapDays: 14),
                                 newestMessageID: 9, now: now)
        #expect(item?.kind == .quiet)
        #expect(item?.text == "You usually talk every 2 weeks; it's been 5 weeks")
        #expect(item?.steer == "reconnect")
        #expect(item?.since == now.addingTimeInterval(-35 * day))
        #expect(item?.newestMessageID == 9)
    }

    @Test func onScheduleIsNotQuiet() {
        #expect(Waiting.quiet(in: conversation(), metrics: metrics(lastLongDaysAgo: 10, usualGapDays: 14),
                              newestMessageID: 9, now: now) == nil)
    }

    @Test func groupsAreNeverQuiet() {
        #expect(Waiting.quiet(in: conversation(group: true), metrics: metrics(lastLongDaysAgo: 35, usualGapDays: 14),
                              newestMessageID: 9, now: now) == nil)
    }

    @Test(arguments: [(1.0, "every day", "a day"), (3.0, "every 3 days", "3 days"), (14.0, "every 2 weeks", "2 weeks"),
                      (30.0, "every 4 weeks", "4 weeks"), (90.0, "every 3 months", "3 months")])
    func durationsReadNaturally(_ c: (days: Double, every: String, been: String)) {
        #expect(Waiting.every(c.days * day) == c.every)
        #expect(Waiting.been(c.days * day) == c.been)
    }
}

@Suite struct WaitingRankTests {
    func item(_ id: Int64, _ kind: Waiting.Kind, daysAgo: Double, newest: Int64 = 100) -> Waiting {
        Waiting(conversationID: id, kind: kind, text: "", steer: "", since: now.addingTimeInterval(-daysAgo * day),
                newestMessageID: newest)
    }

    @Test func mostUrgentKindFirstThenOldest() {
        let ranked = Waiting.rank([item(1, .quiet, daysAgo: 40), item(2, .unanswered, daysAgo: 1), item(3, .asked, daysAgo: 1),
                                   item(4, .unanswered, daysAgo: 3), item(5, .promised, daysAgo: 2)])
        #expect(ranked.map(\.conversationID) == [3, 4, 2, 5, 1])
    }

    @Test func oneRowPerConversationUnderItsMostUrgentKind() {
        let ranked = Waiting.rank([item(1, .promised, daysAgo: 5), item(1, .unanswered, daysAgo: 1), item(1, .quiet, daysAgo: 40)])
        #expect(ranked.map(\.kind) == [.unanswered])
    }

    @Test func oldestPromiseRepresentsAConversation() {
        let ranked = Waiting.rank([item(1, .promised, daysAgo: 2), item(1, .promised, daysAgo: 9)])
        #expect(ranked.map(\.since) == [now.addingTimeInterval(-9 * day)])
    }

    @Test func dismissedStaysHiddenUntilSomethingNewArrives() {
        #expect(Waiting.rank([item(1, .asked, daysAgo: 1, newest: 100)], dismissed: [1: 100]).isEmpty)
        #expect(Waiting.rank([item(1, .asked, daysAgo: 1, newest: 101)], dismissed: [1: 100]).count == 1)
        #expect(Waiting.rank([item(2, .asked, daysAgo: 1)], dismissed: [1: 100]).count == 1)
    }

    @Test func aPromiseCarriesItsTaskAndNothingElseDoes() {
        let conversation = Conversation(chats: [Chat(id: 1, identifier: "maya@example.com", displayName: nil, isGroup: false,
                                                     participants: ["maya@example.com"], messageCount: 1, lastMessageDate: nil)])
        let promised = Waiting.promised(in: conversation, task: "Send the Big Sur photos", made: now, newestMessageID: 1)
        #expect(promised.promise == "send the Big Sur photos")
        #expect(Waiting.unanswered(in: conversation, messages: [w(1, me: false, "dinner friday?", hoursAgo: 3)], now: now)?.promise == nil)
    }
}
