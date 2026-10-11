import Foundation
import Testing
@testable import OdeCore

@Suite struct OdeLinesTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Thursday 2026-10-15, 10:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_058_400)
    func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    @Test func firstNamesComeFromTitles() {
        #expect(OdeLines.firstName("Maya Chen") == "Maya")
        #expect(OdeLines.firstName("Priya") == "Priya")
        #expect(OdeLines.firstName("+13105550199") == "+13105550199")
    }

    @Test func daysAreCountedByCalendarDay() {
        #expect(OdeLines.when(ago(hours: 2), now: now, calendar: calendar) == "earlier today")
        #expect(OdeLines.when(ago(hours: 11), now: now, calendar: calendar) == "yesterday")
        #expect(OdeLines.when(ago(hours: 48), now: now, calendar: calendar) == "on Tuesday")
        #expect(OdeLines.when(ago(hours: 24 * 9), now: now, calendar: calendar) == "last week")
        #expect(OdeLines.when(ago(hours: 24 * 18), now: now, calendar: calendar) == "a couple of weeks ago")
        #expect(OdeLines.when(ago(hours: 24 * 60), now: now, calendar: calendar) == "a while ago")
    }

    @Test func waitingLinesNeverQuoteThem() {
        #expect(OdeLines.waiting(.asked, name: "Maya", since: ago(hours: 48), promise: nil, now: now, calendar: calendar)
                == "Maya asked you something on Tuesday.")
        #expect(OdeLines.waiting(.unanswered, name: "Sam", since: ago(hours: 11), promise: nil, now: now, calendar: calendar)
                == "Sam wrote to you yesterday.")
        #expect(OdeLines.waiting(.quiet, name: "Dad", since: ago(hours: 24 * 21), promise: nil, now: now, calendar: calendar)
                == "It's been a while since you talked with Dad.")
    }

    @Test func promisesAreSpokenAsYourWords() {
        #expect(OdeLines.waiting(.promised, name: "Maya", since: ago(hours: 24 * 5), promise: "Send the Big Sur photos",
                                 now: now, calendar: calendar) == "You told Maya you'd send the Big Sur photos.")
    }

    @Test func routingAndQuestions() {
        #expect(OdeLines.routed(name: "Maya") == "Maya. Here's a start, in your words.")
        #expect(OdeLines.which(["Sam Lee", "Sam Ortiz"]) == "Which one: Sam Lee or Sam Ortiz?")
        #expect(OdeLines.which(["Sam Lee", "Sam Ortiz", "Sam Wu"]) == "Which one: Sam Lee, Sam Ortiz or Sam Wu?")
    }

    @Test func promisesComeFirstThenRemindersUpToThree() {
        #expect(VoiceSuggestions.make(openLoops: ["Send the Big Sur photos"],
                                      reminders: ["Her sister's wedding in Portland", "Second-round interview Thursday",
                                                  "Moving to Denver in March"],
                                      draft: "Running late, start without me")
                == ["Send the Big Sur photos", "Her sister's wedding in Portland", "Second-round interview Thursday"])
    }

    @Test func coveredSuggestionsAreLeftOut() {
        #expect(VoiceSuggestions.make(openLoops: ["Send the Big Sur photos"], reminders: [],
                                      draft: "I'll send the photos tonight").isEmpty)
    }

    @Test func duplicatesAreOfferedOnce() {
        #expect(VoiceSuggestions.make(openLoops: ["Call the landlord"], reminders: ["call the landlord", ""],
                                      draft: "ok") == ["Call the landlord"])
    }
}
