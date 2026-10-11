# Ode Speaks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ode answers you out loud in short lines of its own ("Maya asked you something on Tuesday", "Which one: Sam Lee or Sam Ortiz?"), and the "In your words" draft offers what Ode knows as one-tap suggestions ("Mention: send the Big Sur photos") instead of writing it in for you.

**Architecture:** Two pure pieces in OdeCore: `OdeLines` builds every spoken line from templates and never from anyone's message text, and `VoiceSuggestions` picks up to three things worth mentioning (your open promises first, then reminders) that the draft doesn't already cover. The app adds `OdeVoice` (an `AVSpeechSynthesizer` with the best installed system voice, a Settings toggle, silenced the moment you press Space), speaks lines from `MainView.route`, and shows suggestion buttons under the "In your words" draft that revise it through the existing voice revision.

**Tech Stack:** Swift 6, SwiftUI (macOS 26), AVFoundation (`AVSpeechSynthesizer`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (section "Voice": "Ode's lines" and "Voice keeps your words").

## Global Constraints

- Ode speaks only its own template lines, plus names, times and your own promises. It never reads anyone's message aloud.
- Speech is on by default, with a Settings toggle stored in UserDefaults under `odeSpeaks`, and stops the moment Space is pressed.
- Suggestions come from your confirmed open promises first, then reminders already extracted for that person; at most three; none the draft already covers. Tapping one revises the draft to include it. Suggestions never insert text by themselves.
- No new model calls: suggestions use cached reminders only.
- Code style: no comments that restate code, conventional commits, no emojis.
- Commands: prefix Swift and Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Review Focus

1. A promised item's spoken line must say your promise ("You told Maya you'd send the photos"), never their last message. Covered by `promisesAreSpokenAsYourWords` in Task 1; `MainView` takes the task from the steer, not from `Waiting.text`.
2. A time from late last night, said shortly after midnight, must read "yesterday", not "earlier today". Covered by `daysAreCountedByCalendarDay` in Task 1.
3. A suggestion the draft already covers ("send the photos" when the draft says "I'll send the photos tonight") must not be offered. Covered by `coveredSuggestionsAreLeftOut` in Task 1.
4. Pressing Space while Ode is talking must silence it immediately. `OdeVoice.stop()` is called on `.start`; checked manually in Task 3.
5. Turning the toggle off must stop all speech, including mid-sentence. `say` checks the setting; checked manually in Task 3.

---

### Task 1: OdeLines and VoiceSuggestions

**Files:**
- Create: `OdeCore/Sources/OdeCore/OdeLines.swift`
- Modify: `OdeCore/Sources/OdeCore/VoicePrompt.swift` (add `VoiceSuggestions`; expose `VoiceCheck.contentStems`)
- Test: `OdeCore/Tests/OdeCoreTests/OdeLinesTests.swift`

**Interfaces:**
- Consumes: `Waiting.Kind` (existing).
- Produces:
  - `public enum OdeLines` with `firstName(_ title: String) -> String`, `when(_ date: Date, now: Date, calendar: Calendar = .current) -> String`, `waiting(_ kind: Waiting.Kind, name: String, since: Date, promise: String?, now: Date, calendar: Calendar = .current) -> String`, `routed(name: String) -> String`, `which(_ names: [String]) -> String`, and constants `whoFor`, `caughtUp`.
  - `public enum VoiceSuggestions { public static func make(openLoops: [String], reminders: [String], draft: String, limit: Int = 3) -> [String] }`

- [ ] **Step 1: Write the failing tests**

Create `OdeCore/Tests/OdeCoreTests/OdeLinesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter OdeLinesTests 2>&1 | grep -E "error:" | grep -v SwiftCompile | head -2`
Expected: "cannot find 'OdeLines' in scope".

- [ ] **Step 3: Implement**

Create `OdeCore/Sources/OdeCore/OdeLines.swift`:

```swift
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
```

In `OdeCore/Sources/OdeCore/VoicePrompt.swift`, add inside `VoiceCheck` (next to `stem`):

```swift
    static func contentStems(_ text: String) -> [String] {
        words(text).map { shorthand[$0] ?? $0 }.filter { $0.count >= 4 && !stopWords.contains($0) }.map(stem)
    }
```

and at the end of the file:

```swift
/// What Ode knows that's worth mentioning, offered as a tap rather than written in. Your promises come first.
public enum VoiceSuggestions {
    public static func make(openLoops: [String], reminders: [String], draft: String, limit: Int = 3) -> [String] {
        let covered = Set(VoiceCheck.contentStems(draft))
        var seen = Set<String>()
        var picked: [String] = []
        for candidate in openLoops + reminders {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            let stems = VoiceCheck.contentStems(text)
            if !stems.isEmpty, stems.filter(covered.contains).count * 2 >= stems.count { continue }
            picked.append(text)
            if picked.count == limit { break }
        }
        return picked
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore 2>&1 | grep -E "✘ Test .*failed|Test run" | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/OdeLines.swift OdeCore/Sources/OdeCore/VoicePrompt.swift OdeCore/Tests/OdeCoreTests/OdeLinesTests.swift
git commit -m "feat(core): Ode's spoken lines and what's worth mentioning"
```

---

### Task 2: Suggestions under "In your words"

**Files:**
- Modify: `Ode/AppModel.swift` (next to `reminders(for:)`, ~line 125)
- Modify: `Ode/DraftComposerView.swift` (the composer's `if !drafts.isEmpty { ForEach … }` block, ~line 160)

**Interfaces:**
- Consumes: `VoiceSuggestions.make` (Task 1); `AppModel.confirmedLoops(for:)`, `revise(_:)`, `inYourWords`, `selectedText` (existing).
- Produces: `AppModel.cachedReminders(for: PersonHealth) -> [Reminder]`.

- [ ] **Step 1: Cached reminders only**

In `Ode/AppModel.swift`, after `reminders(for:)`:

```swift
    /// Reminders already extracted, without starting a model call.
    func cachedReminders(for person: PersonHealth) -> [Reminder] {
        remindersCache[person.id] ?? []
    }
```

- [ ] **Step 2: Show the suggestions**

In `Ode/DraftComposerView.swift`, add a computed property next to `inYourWords`:

```swift
    private var suggestions: [String] {
        guard inYourWords, work == nil else { return [] }
        return VoiceSuggestions.make(openLoops: model.confirmedLoops(for: person).map(\.task),
                                     reminders: model.cachedReminders(for: person).map(\.text), draft: selectedText ?? "")
    }
```

and right after the closing brace of the `ForEach(drafts) { … }` inside `if !drafts.isEmpty {`:

```swift
                    if !suggestions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button("Mention: \(suggestion)") { revise("Also mention: \(suggestion)") }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .lineLimit(1)
                            }
                        }
                    }
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Ode/AppModel.swift Ode/DraftComposerView.swift
git commit -m "feat(app): offer what Ode knows as suggestions under your words"
```

---

### Task 3: OdeVoice

**Files:**
- Create: `Ode/OdeVoice.swift`
- Modify: `Ode/SettingsView.swift` (the "Messages access" section, after the live-sync caption, ~line 329)
- Modify: `Ode/MainView.swift` (`installPushToTalk` `.start` case; `route(_:)`)

**Interfaces:**
- Consumes: `OdeLines` (Task 1); `Waiting` (existing).
- Produces: `@MainActor final class OdeVoice { static let settingKey = "odeSpeaks"; func say(_ line: String); func stop() }`.

- [ ] **Step 1: Write OdeVoice**

Create `Ode/OdeVoice.swift`:

```swift
import AVFoundation

/// Ode's own short lines, out loud, in the best voice installed on this Mac. Never anyone's messages.
@MainActor
final class OdeVoice {
    static let settingKey = "odeSpeaks"

    private let synthesizer = AVSpeechSynthesizer()
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }()

    func say(_ line: String) {
        stop()
        guard UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true else { return }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.voice
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

- [ ] **Step 2: The Settings toggle**

In `Ode/SettingsView.swift`, add `@AppStorage(OdeVoice.settingKey) private var odeSpeaks = true` with the view's other properties, and after the "When on, Ode checks for new messages…" caption:

```swift
            Toggle("Ode says its short lines out loud", isOn: $odeSpeaks).toggleStyle(.checkbox)
            Text("Things like \u{201C}Maya asked you something on Tuesday.\u{201D} Ode never reads anyone\u{2019}s messages aloud.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
```

If that section belongs to a struct other than the one holding the toggle's other state, put the `@AppStorage` property in the struct that contains this code.

- [ ] **Step 3: Speak from MainView**

In `Ode/MainView.swift`, add `@State private var voice = OdeVoice()`. In `installPushToTalk`, in the `.start` case, call `voice.stop()` before `capture.press()`. Replace `route(_:)`'s `switch` with:

```swift
        switch VoiceIntent.parse(text, people: model.voicePeople, focused: draftRequest?.person.id) {
        case .reply(let id, let request):
            guard let person = model.people.first(where: { $0.id == id }) else { return }
            draftRequest = DraftRequest(person: person, steer: "", spoken: request)
            voice.say(OdeLines.routed(name: OdeLines.firstName(person.title)))
        case .ambiguous(let ids, let request):
            let people = model.people.filter { ids.contains($0.id) }
            notice = .which(people, request)
            voice.say(OdeLines.which(people.map(\.title)))
        case .edit(let instruction):
            pendingEdit = instruction
        case .ask:
            guard let item = model.waiting.first, let person = model.people.first(where: { $0.id == item.conversationID }) else {
                notice = .allCaughtUp
                voice.say(OdeLines.caughtUp)
                return
            }
            draftRequest = DraftRequest(person: person, steer: item.steer)
            let promise = item.steer.hasPrefix("follow up on: ") ? String(item.steer.dropFirst("follow up on: ".count)) : nil
            voice.say(OdeLines.waiting(item.kind, name: OdeLines.firstName(person.title), since: item.since, promise: promise, now: .now))
        case .unknown(let heard):
            typed = heard
            notice = .whoFor
            voice.say(OdeLines.whoFor)
        }
```

The promise comes from the steer (`"follow up on: {task}"`, set by `Waiting.promised`), never from `item.text`, so a promised line can't carry their words.

- [ ] **Step 4: Build and run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore 2>&1 | tail -1`
Expected: all tests pass.

- [ ] **Step 5: Check it in the running app (Joe)**

1. Hold Space, say "tell ‹someone› I'm running late": Ode says "‹Name›. Here's a start, in your words."
2. Hold Space, say "who should I check on": Ode says a line about the top person and opens them. It never reads their message.
3. While Ode is talking, press Space: it stops at once.
4. In the "In your words" composer for someone with an open promise: a "Mention: …" button appears; tapping it revises the draft to include it, and the button disappears.
5. Settings: turn "Ode says its short lines out loud" off; repeat 1: silence.

If you're an agent without access to the GUI, say these steps weren't run.

- [ ] **Step 6: Commit**

```bash
git add Ode/OdeVoice.swift Ode/SettingsView.swift Ode/MainView.swift
git commit -m "feat(app): Ode says its short lines out loud"
```
