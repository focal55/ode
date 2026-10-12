import Foundation
import Testing
@testable import OdeCore

@Suite struct PlazaHeadlineTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Thursday 2026-10-15, 10:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_058_400)
    let titles: [Int64: String] = [1: "Maya Chen", 2: "Sam Ortiz", 3: "Priya", 4: "Book Club Crew", 5: "Dev", 6: "Ana", 7: "Bo",
                                   8: "Cy", 9: "Di", 10: "Ed", 11: "Flo", 12: "Gus"]

    func waiting(_ ids: [Int64]) -> [Waiting] {
        ids.map { Waiting(conversationID: $0, kind: .asked, text: "", steer: "", since: now, newestMessageID: 1) }
    }

    func kept(hoursAgo: Double) -> Kept {
        Kept(conversationID: 9, handoffAt: now.addingTimeInterval(-hoursAgo * 3_600 - 60),
             sentAt: now.addingTimeInterval(-hoursAgo * 3_600), messageID: 1)
    }

    func line(_ ids: [Int64], kept: [Kept] = [], groups: Set<Int64> = []) -> PlazaHeadline.Line {
        PlazaHeadline.make(waiting: waiting(ids), titles: titles, groups: groups, kept: kept, now: now, calendar: calendar)
    }

    @Test func nobodyWaiting() {
        #expect(line([]) == .init(title: "Everyone's heard from you.", subtitle: nil))
        #expect(line([], kept: [kept(hoursAgo: 1)]) == .init(title: "Everyone's heard from you.", subtitle: nil))
    }

    @Test func oneWaitingNamesThem() {
        #expect(line([1]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }

    @Test func oneLeftAfterKeepingSomeoneToday() {
        #expect(line([1], kept: [kept(hoursAgo: 2)]) == .init(title: "One more.", subtitle: "Maya would love to hear from you."))
    }

    @Test func keptYesterdayDoesNotCount() {
        #expect(line([1], kept: [kept(hoursAgo: 11)]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }

    @Test func severalWaitingAreCountedInWords() {
        #expect(line([2, 1, 3]) == .init(title: "Three people would love to hear from you.", subtitle: "Start with Sam."))
        #expect(line(Array(1...10)) == .init(title: "Ten people would love to hear from you.", subtitle: "Start with Maya."))
    }

    @Test func moreThanTenUseDigits() {
        #expect(line(Array(1...12)).title == "12 people would love to hear from you.")
    }

    @Test func groupsAreNamedByTheirTitle() {
        #expect(line([4, 1], groups: [4]).subtitle == "Start with Book Club Crew.")
    }

    @Test func untrackedConversationsAreNotCountedOrNamed() {
        #expect(line([99, 1]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }
}
