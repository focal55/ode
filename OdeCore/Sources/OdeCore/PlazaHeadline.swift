import Foundation

/// The Plaza's headline: who would love to hear from you, without scores, streaks or guilt.
public enum PlazaHeadline {
    public struct Line: Sendable, Equatable {
        public let title: String
        public let subtitle: String?

        public init(title: String, subtitle: String?) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public static func make(waiting: [Waiting], titles: [Int64: String], groups: Set<Int64>, kept: [Kept], now: Date,
                            calendar: Calendar = .current) -> Line {
        let names = waiting.compactMap { item in
            titles[item.conversationID].map { groups.contains(item.conversationID) ? $0 : OdeLines.firstName($0) }
        }
        guard let first = names.first else { return Line(title: "Everyone's heard from you.", subtitle: nil) }
        guard names.count > 1 else {
            let keptToday = kept.contains { calendar.isDate($0.sentAt, inSameDayAs: now) }
            let line = "\(first) would love to hear from you."
            return keptToday ? Line(title: "One more.", subtitle: line) : Line(title: line, subtitle: nil)
        }
        return Line(title: "\(count(names.count)) people would love to hear from you.", subtitle: "Start with \(first).")
    }

    private static func count(_ number: Int) -> String {
        let words = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return (2...10).contains(number) ? words[number - 2] : String(number)
    }
}
