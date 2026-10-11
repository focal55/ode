import Foundation
import Testing
@testable import OdeCore

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func m(_ id: Int64, me: Bool, _ text: String?, minutes: Double, chat: Int64 = 1,
               kind: Message.Kind = .text) -> Message {
    Message(id: id, guid: "c\(chat)-\(id)", chatID: chat, sender: me ? nil : "+15550001111", isFromMe: me,
            date: start.addingTimeInterval(minutes * 60), text: text, textSource: .column, kind: kind)
}

@Suite struct ReplyMomentTests {
    @Test func replyToTheirTextIsAMomentWithOnlyEarlierContext() {
        let messages = [
            m(1, me: false, "are you coming saturday", minutes: 0),
            m(2, me: true, "yes, I'll bring the cake", minutes: 5),
            m(3, me: false, "amazing", minutes: 6),
        ]
        let moments = ReplyMoments.find(in: messages)
        #expect(moments.map(\.actual.id) == [2])
        #expect(moments.first?.context.map(\.id) == [1])
    }

    @Test func onlyTheFirstMessageOfABurstCounts() {
        let messages = [
            m(1, me: false, "how did it go", minutes: 0),
            m(2, me: true, "really well I think", minutes: 1),
            m(3, me: true, "they want a second round", minutes: 2),
        ]
        #expect(ReplyMoments.find(in: messages).map(\.actual.id) == [2])
    }

    @Test func shortAcknowledgementsAndSlowRepliesAreSkipped() {
        let messages = [
            m(1, me: false, "dinner was great", minutes: 0),
            m(2, me: true, "same!", minutes: 1),
            m(3, me: false, "want to do it again", minutes: 10),
            m(4, me: true, "sorry just saw this, yes please", minutes: 10 + 13 * 60),
        ]
        #expect(ReplyMoments.find(in: messages).isEmpty)
    }

    @Test func reactionsBetweenDoNotHideTheReply() {
        let messages = [
            m(1, me: false, "can you call me later", minutes: 0),
            m(2, me: true, nil, minutes: 1, kind: .reaction),
            m(3, me: true, "yep after work around six", minutes: 2),
        ]
        #expect(ReplyMoments.find(in: messages).map(\.actual.id) == [3])
    }

    @Test func sampleTakesTurnsAcrossChatsAndIsStable() {
        let chatA = (0..<5).map { ReplyMoment(context: [], actual: m(Int64($0), me: true, "a b c", minutes: 0, chat: 1)) }
        let chatB = (0..<2).map { ReplyMoment(context: [], actual: m(Int64($0), me: true, "a b c", minutes: 0, chat: 2)) }
        let first = ReplyMoments.sample([chatA, chatB], count: 4)
        #expect(first.map(\.actual.chatID) == [1, 2, 1, 2])
        #expect(ReplyMoments.sample([chatA, chatB], count: 4) == first)
        #expect(ReplyMoments.sample([chatA, chatB], count: 10).count == 7)
    }
}
