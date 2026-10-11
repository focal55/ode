import Foundation

/// Everything Ode says out loud. Built from templates, names, times and your own promises; never from their messages.
public enum OdeLines {
    public static let whoFor = "Who's it for?"
    public static let caughtUp = "Nobody's waiting on you."

    public static func firstName(_ title: String) -> String {
        guard title.contains(where: \.isLetter), let first = title.split(separator: " ").first else { return title }
        return String(first)
    }

    public static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "earlier today"
        case 1: return "yesterday"
        case 2...6: return "on " + calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
        case 7...13: return "last week"
        case 14...27: return "a couple of weeks ago"
        default: return "a while ago"
        }
    }

    public static func waiting(_ kind: Waiting.Kind, name: String, since: Date, promise: String?, now: Date,
                               calendar: Calendar = .current) -> String {
        switch kind {
        case .asked: return "\(name) asked you something \(when(since, now: now, calendar: calendar))."
        case .unanswered: return "\(name) wrote to you \(when(since, now: now, calendar: calendar))."
        case .promised:
            guard let promise, !promise.isEmpty else { return "You promised \(name) something." }
            return "You told \(name) you'd \(promise.prefix(1).lowercased() + promise.dropFirst())."
        case .quiet: return "It's been a while since you talked with \(name)."
        }
    }

    public static func routed(name: String) -> String {
        "\(name). Here's a start, in your words."
    }

    public static func which(_ names: [String]) -> String {
        guard names.count > 1 else { return "Which one?" }
        return "Which one: " + names.dropLast().joined(separator: ", ") + " or " + names.last! + "?"
    }
}
