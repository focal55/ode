import Foundation
import Testing
@testable import OdeCore

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let hour: TimeInterval = 3_600

private func message(_ id: Int64, me: Bool, at offset: TimeInterval, kind: Message.Kind = .text) -> Message {
    Message(id: id, guid: "\(id)", chatID: 7, sender: me ? nil : "maya@example.com", isFromMe: me,
            date: start.addingTimeInterval(offset), text: kind == .text ? "hi" : nil, textSource: .column, kind: kind)
}

@Suite struct KeptDetectorTests {
    let handoff = Handoff(conversationID: 7, at: start)

    @Test func aSendAfterTheHandoffIsKept() {
        let thread = [message(1, me: false, at: -hour), message(2, me: true, at: 120)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept == [Kept(conversationID: 7, handoffAt: start, sentAt: start.addingTimeInterval(120), messageID: 2)])
        #expect(result.pending.isEmpty)
    }

    @Test func aSendBeforeTheHandoffDoesNotCount() {
        let thread = [message(1, me: true, at: -60)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept.isEmpty)
        #expect(result.pending == [handoff])
    }

    @Test func theirMessagesDoNotCount() {
        let thread = [message(1, me: false, at: 60)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept.isEmpty)
        #expect(result.pending == [handoff])
    }

    @Test func reactionsDoNotCount() {
        let thread = [message(1, me: true, at: 60, kind: .reaction)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept.isEmpty)
    }

    @Test func attachmentsCount() {
        let thread = [message(1, me: true, at: 60, kind: .attachmentOnly)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept.map(\.messageID) == [1])
    }

    @Test func aSendInAnotherConversationDoesNotCount() {
        let result = KeptDetector.detect(handoffs: [handoff], threads: [8: [message(1, me: true, at: 60)]],
                                         now: start.addingTimeInterval(300))
        #expect(result.kept.isEmpty)
        #expect(result.pending == [handoff])
    }

    @Test func aSendAfterTheWindowDoesNotCountAndTheHandoffExpires() {
        let thread = [message(1, me: true, at: 25 * hour)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(26 * hour))
        #expect(result.kept.isEmpty)
        #expect(result.pending.isEmpty)
    }

    @Test func aLateCheckStillFindsASendInsideTheWindow() {
        let thread = [message(1, me: true, at: 2 * hour)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(40 * hour))
        #expect(result.kept.map(\.messageID) == [1])
    }

    @Test func theFirstQualifyingSendIsTheOneRecorded() {
        let thread = [message(1, me: true, at: 60), message(2, me: true, at: 90)]
        let result = KeptDetector.detect(handoffs: [handoff], threads: [7: thread], now: start.addingTimeInterval(300))
        #expect(result.kept.map(\.messageID) == [1])
    }

    @Test func anUnsentHandoffInsideTheWindowStaysPending() {
        let result = KeptDetector.detect(handoffs: [handoff], threads: [:], now: start.addingTimeInterval(hour))
        #expect(result.kept.isEmpty)
        #expect(result.pending == [handoff])
    }
}
