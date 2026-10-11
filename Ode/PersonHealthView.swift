import Charts
import OdeCore
import SwiftUI

/// The design's Patterns screen for one person: range, headline tiles with change against the
/// previous period, weekly volume, computed patterns, and things to remember.
struct PersonHealthView: View {
    enum Range: String, CaseIterable {
        case quarter = "90d"
        case year = "1y"
        case all = "All"

        var days: Double? {
            switch self {
            case .quarter: 90
            case .year: 365
            case .all: nil
            }
        }
    }

    let model: AppModel
    let person: PersonHealth
    let openMoment: (Int64) -> Void

    @State private var range = Range.year
    @State private var reminders: [Reminder]?

    private var messages: [Message] { model.threads[person.id] ?? [] }

    private func window(_ offset: Double) -> [Message] {
        guard let days = range.days else { return offset == 0 ? messages : [] }
        let end = Date.now.addingTimeInterval(-offset * days * 86_400)
        let start = end.addingTimeInterval(-days * 86_400)
        return messages.filter { $0.date >= start && $0.date < end }
    }

    var body: some View {
        let current = RelationshipMetrics.compute(window(0))
        let previous = range == .all ? nil : RelationshipMetrics.compute(window(1))
        let patterns = model.patterns(for: person)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(current, patterns)
                tiles(current, previous)
                chart
                HStack(alignment: .top, spacing: 20) {
                    patternsCard(patterns).frame(maxWidth: .infinity)
                    rememberCard.frame(width: 360)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: 1240, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.ground)
        .task(id: person.id) {
            reminders = nil
            reminders = await model.reminders(for: person)
        }
    }

    private func header(_ metrics: RelationshipMetrics, _ patterns: [Patterns.Pattern]) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            Avatar(title: person.title, photo: person.photo, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.title).font(.system(size: 34, weight: .semibold)).tracking(-1)
                Text(subtitle).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 14) {
                rangePicker
                Text(summary(patterns)).font(.system(size: 16)).frame(maxWidth: 440, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let label = model.labels[person.id] { parts.append(label.rawValue) }
        parts.append("\(person.messageCount.formatted()) messages")
        let since = model.since(person).map { " since \($0.formatted(.dateTime.year()))" } ?? ""
        return parts.joined(separator: " · ") + since
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(Range.allCases, id: \.self) { option in
                Button { range = option } label: {
                    Text(option.rawValue)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .foregroundStyle(range == option ? Theme.ink : Theme.secondary)
                        .background(range == option ? Theme.surface : .clear, in: .rect(cornerRadius: 7))
                        .shadow(color: range == option ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(red: 0.929, green: 0.929, blue: 0.918), in: .rect(cornerRadius: 9))
    }

    /// One or two sentences from the strongest facts, so the header reads like the design.
    private func summary(_ patterns: [Patterns.Pattern]) -> String {
        var sentences: [String] = []
        let all = RelationshipMetrics.compute(messages)
        var first: [String] = []
        if let day = patterns.first(where: { $0.kind == .longTalkDay }) {
            first.append("You talk most on \(day.title.components(separatedBy: " ").first ?? "")s")
        }
        if let share = all.youStartShare {
            if share < 0.3 { first.append("\(first.isEmpty ? "They" : "they") start nearly every conversation") }
            else if share > 0.7 { first.append("\(first.isEmpty ? "You" : "you") start nearly every conversation") }
        }
        if !first.isEmpty { sentences.append(first.joined(separator: " and ") + ".") }
        if let speed = patterns.first(where: { $0.kind == .replySpeed }) { sentences.append(speed.detail) }
        return sentences.isEmpty ? "Not enough history yet to say what’s typical." : sentences.joined(separator: " ")
    }

    private func tiles(_ current: RelationshipMetrics, _ previous: RelationshipMetrics?) -> some View {
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        let period = range == .year ? "vs last year" : "vs previous 90 days"
        let theyStart = current.youStartShare.map { 1 - $0 }
        let theyBefore = previous?.youStartShare.map { 1 - $0 }
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                Tile(label: person.conversation.isGroup ? "Others start" : "They start", value: theyStart.map { $0.formatted(percent) } ?? "—",
                     detail: delta(theyStart, theyBefore, period: period) { "\(Int(($0 * 100).rounded())) pts" }.text,
                     detailColor: delta(theyStart, theyBefore, period: period) { _ in "" }.worse ? Theme.warning : Theme.muted)
                Tile(label: "Your median reply", value: Elapsed.short(current.yourMedianReply),
                     detail: delta(current.yourMedianReply, previous?.yourMedianReply, period: period) { Elapsed.short(abs($0)) }.text,
                     detailColor: delta(current.yourMedianReply, previous?.yourMedianReply, period: period) { _ in "" }.worse ? Theme.warning : Theme.muted)
                Tile(label: "Their median reply", value: Elapsed.short(current.theirMedianReply),
                     detail: delta(current.theirMedianReply, previous?.theirMedianReply, period: period) { Elapsed.short(abs($0)) }.text)
                Tile(label: "Last long talk", value: current.lastLongConversation.map { Elapsed.ago($0) } ?? "—",
                     detail: current.usualGapBetweenLongConversations.map { "usually every \(Elapsed.short($0))" } ?? "none in this range")
            }
        }
        .background(Theme.hairline)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    /// "+9 pts vs last year", "steady", or empty for All. Higher is worse for the measures shown.
    private func delta(_ now: Double?, _ before: Double?, period: String, format: (Double) -> String) -> (text: String, worse: Bool) {
        guard range != .all else { return ("all time", false) }
        guard let now, let before, before > 0 else { return ("no earlier data", false) }
        let change = now - before
        guard abs(change) / before >= 0.1 else { return ("steady", false) }
        return ("\(change > 0 ? "+" : "−")\(format(abs(change))) \(period)", change > 0)
    }

    private var chart: some View {
        let weeks = range == .quarter ? 13 : range == .year ? 52 : 104
        let series = Self.weekly(messages, weeks: weeks)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Messages per week").font(.system(size: 15, weight: .semibold))
                legend(Theme.accent, person.conversation.isGroup ? "Others" : "Them")
                legend(Theme.ink, "You")
                Spacer()
                if let first = series.first?.start {
                    Text("\(first.formatted(.dateTime.month(.abbreviated).year())) – \(Date.now.formatted(.dateTime.month(.abbreviated).year()))".uppercased())
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            Chart {
                ForEach(series, id: \.start) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Messages", week.theirs))
                        .foregroundStyle(Theme.accent)
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Messages", week.mine))
                        .foregroundStyle(Theme.ink)
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month, count: range == .quarter ? 1 : 3)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .frame(height: 180)
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private static func weekly(_ messages: [Message], weeks: Int) -> [RelationshipMetrics.Week] {
        let week: TimeInterval = 7 * 86_400
        let now = Date.now
        var mine = Array(repeating: 0, count: weeks), theirs = Array(repeating: 0, count: weeks)
        for message in messages where message.kind == .text || message.kind == .attachmentOnly {
            let bucket = weeks - 1 - Int(now.timeIntervalSince(message.date) / week)
            guard (0..<weeks).contains(bucket) else { continue }
            if message.isFromMe { mine[bucket] += 1 } else { theirs[bucket] += 1 }
        }
        return (0..<weeks).map { RelationshipMetrics.Week(start: now.addingTimeInterval(-Double(weeks - $0) * week), mine: mine[$0], theirs: theirs[$0]) }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private func patternsCard(_ patterns: [Patterns.Pattern]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Patterns Ode noticed").font(.system(size: 15, weight: .semibold)).padding(.bottom, 10)
            if patterns.isEmpty {
                Text("Nothing stands out yet; patterns need a few months of conversation.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.vertical, 12)
            }
            ForEach(Array(patterns.enumerated()), id: \.element.id) { index, pattern in
                Divider().overlay(Color(red: 0.937, green: 0.937, blue: 0.925))
                HStack(alignment: .top, spacing: 14) {
                    Text(String(format: "%02d", index + 1)).font(Theme.mono(11)).foregroundStyle(Theme.accent).frame(width: 28, alignment: .leading)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pattern.title).font(.system(size: 14, weight: .medium))
                        Text(pattern.detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if let latest = pattern.momentIDs.last {
                        Button("See \(pattern.momentIDs.count) moments") { openMoment(latest) }
                            .buttonStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private var rememberCard: some View {
        let open = model.confirmedLoops(for: person)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Remember").font(.system(size: 15, weight: .semibold)).padding(.bottom, 10)
            if reminders == nil {
                ProgressView().controlSize(.small).padding(.vertical, 12)
            } else if (reminders ?? []).isEmpty && open.isEmpty {
                Text("Nothing coming up that they mentioned.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.vertical, 12)
            }
            ForEach(Array((reminders ?? []).enumerated()), id: \.offset) { _, reminder in
                rememberRow(reminder.when.uppercased(), reminder.text)
            }
            ForEach(open) { loop in
                rememberRow("OPEN", "You said: \(loop.task.prefix(1).lowercased() + loop.task.dropFirst())")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private func rememberRow(_ when: String, _ text: String) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Color(red: 0.937, green: 0.937, blue: 0.925))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(when).font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                Text(text).font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        }
    }
}

#Preview {
    let model = AppModel.preview()
    PersonHealthView(model: model, person: model.people[0]) { _ in }
        .frame(width: 1160, height: 980)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
}
