# Avatars and Kept Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** People show their Contacts photo everywhere Ode draws an avatar, and every reply that starts in Ode is logged so we can count the ones you actually send ("kept"), the metric the Lantern Plaza will be judged against.

**Architecture:** OdeCore's `HandleDirectory` learns each contact's photo and nickname; a conversation's photo resolves through the existing contact key, so merged phone and email chats share one. OdeCore also gains `Handoff`/`Kept` value types, a pure `KeptDetector` that scans conversation threads for a message from you after a handoff, and a `HandoffLog` that persists pending handoffs and the append-only kept log as JSON. The app extracts the composer's Messages handoff into `MessagesHandoff`, records a handoff on "Send via Messages" and "Copy to clipboard", and checks for kept replies after the initial load and after every live-sync cycle.

**Tech Stack:** Swift 6, SwiftUI and AppKit (macOS 26), Contacts framework, Swift Testing, Swift Package Manager (OdeCore).

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (build order step 1; sections "OdeCore (new)", "App (new and changed)", "Judging it").

## Global Constraints

- A handoff is kept by a message **from you** in the same conversation dated strictly after the handoff and no more than 24 hours after it. Reactions (tapbacks) don't count; text and attachment-only messages do. Draft text is never compared.
- Unkept handoffs expire silently 24 hours after they were made. A qualifying send found later (for example, the app was closed) still counts as long as the send itself was inside the window.
- Recording a handoff for a conversation that already has a pending one replaces it, so one send keeps at most one handoff.
- Files: `~/Library/Application Support/Ode/handoffs.json` (pending handoffs) and `~/Library/Application Support/Ode/kept.json` (append-only kept log). JSON with ISO 8601 dates.
- A kept log that fails to decode is never overwritten.
- Group conversations get no photo; their avatar stays initials.
- Ode never sends: the handoff still only copies the draft and opens Messages.
- Code style: no comments that restate code, conventional commits, no emojis.
- Commands: on this Mac `xcode-select` points at the Command Line Tools, so prefix Swift and Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Review Focus

1. Sending from your phone while Ode is open must count: the message arrives through live sync, and `checkKept()` runs after every sync. Covered by `aSendAfterTheHandoffIsKept` in Task 3 and checked manually in Task 5, step 6.
2. Sending while Ode is closed, then opening it the next day, must still count. Covered by `aLateCheckStillFindsASendInsideTheWindow` in Task 3; `checkKept()` runs after `analyze()` in Task 5.
3. Copying, pasting into Messages and tapping a heart (no text) is not a sent reply. Covered by `reactionsDoNotCount` in Task 3.
4. A corrupted `kept.json` must never be silently wiped when the next kept event is appended. Covered by `aCorruptKeptLogIsNeverOverwritten` in Task 4.
5. Handing off to the same person twice before sending must log one kept event, not two. Covered by `recordingAgainReplacesThePendingHandoff` in Task 4.

---

### Task 1: Contact photos and nicknames in HandleDirectory

**Files:**
- Modify: `OdeCore/Sources/OdeCore/HandleDirectory.swift`
- Test: `OdeCore/Tests/OdeCoreTests/HandleDirectoryTests.swift`

**Interfaces:**
- Consumes: `HandleDirectory`, `Conversation`, `Chat` (existing).
- Produces:
  - `HandleDirectory.Entry.init(name: String, phones: [String], emails: [String], nickname: String? = nil, photo: Data? = nil)` with `public let nickname: String?` and `public let photo: Data?`.
  - `public func photo(for handle: String) -> Data?`
  - `public func nickname(for handle: String) -> String?`
  - `public func photo(for conversation: Conversation) -> Data?`: nil for groups, otherwise the first participant whose contact has a photo.

- [ ] **Step 1: Write the failing tests**

Append inside `@Suite struct HandleDirectoryTests` in `OdeCore/Tests/OdeCoreTests/HandleDirectoryTests.swift`, and add `import Foundation` at the top of the file if it isn't there:

```swift
    @Test func photoAndNicknameFollowTheContact() {
        let photo = Data([1, 2, 3])
        let directory = HandleDirectory(entries: [
            .init(name: "Maya Chen", phones: ["+1 555 010 2222"], emails: ["maya@example.com"], nickname: "May", photo: photo),
            .init(name: "Sam Lee", phones: ["5550103333"], emails: []),
        ])
        #expect(directory.photo(for: "+15550102222") == photo)
        #expect(directory.photo(for: "MAYA@example.com") == photo)
        #expect(directory.nickname(for: "maya@example.com") == "May")
        #expect(directory.photo(for: "5550103333") == nil)
        #expect(directory.nickname(for: "5550103333") == nil)
        #expect(directory.photo(for: "+15559999999") == nil)
    }

    @Test func conversationPhotoComesFromAnyParticipantAndNeverForGroups() {
        let photo = Data([9])
        let directory = HandleDirectory(entries: [
            .init(name: "Maya Chen", phones: ["5550102222"], emails: ["maya@example.com"], photo: photo),
        ])
        func chat(_ id: Int64, _ handles: [String], group: Bool = false) -> Chat {
            Chat(id: id, identifier: handles[0], displayName: group ? "Crew" : nil, isGroup: group,
                 participants: handles, messageCount: 1, lastMessageDate: nil)
        }
        let merged = Conversation(chats: [chat(1, ["+15559999999"]), chat(2, ["maya@example.com"])])
        #expect(directory.photo(for: merged) == photo)
        #expect(directory.photo(for: Conversation(chats: [chat(3, ["+15559999999"])])) == nil)
        #expect(directory.photo(for: Conversation(chats: [chat(4, ["+15550102222", "+15559999999"], group: true)])) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HandleDirectoryTests`
Expected: compile failure, "extra arguments at positions #4, #5 in call" or "value of type 'HandleDirectory' has no member 'photo'".

- [ ] **Step 3: Implement**

In `OdeCore/Sources/OdeCore/HandleDirectory.swift`, replace the `Entry` struct and the stored properties and initializer with:

```swift
    public struct Entry: Sendable {
        public let name: String
        public let phones: [String]
        public let emails: [String]
        public let nickname: String?
        public let photo: Data?

        public init(name: String, phones: [String], emails: [String], nickname: String? = nil, photo: Data? = nil) {
            self.name = name
            self.phones = phones
            self.emails = emails
            self.nickname = nickname
            self.photo = photo
        }
    }

    private var entries: [Entry] = []
    private var entryIndex: [String: Int] = [:]

    public init(entries: [Entry] = []) {
        self.entries = entries
        for (index, entry) in entries.enumerated() {
            for key in entry.phones.compactMap(Self.phoneKey) + entry.emails.compactMap(Self.emailKey) where entryIndex[key] == nil {
                entryIndex[key] = index
            }
        }
    }

    public func name(for handle: String) -> String? {
        contactKey(for: handle).map { entries[$0].name }
    }

    public func nickname(for handle: String) -> String? {
        contactKey(for: handle).flatMap { entries[$0].nickname }
    }

    public func photo(for handle: String) -> Data? {
        contactKey(for: handle).flatMap { entries[$0].photo }
    }

    public func photo(for conversation: Conversation) -> Data? {
        guard !conversation.isGroup else { return nil }
        return conversation.participants.lazy.compactMap { photo(for: $0) }.first
    }
```

Remove the old `entryNames` property and the old `name(for:)` body; `contactKey(for:)`, `phoneKey` and `emailKey` stay as they are.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HandleDirectoryTests`
Expected: all HandleDirectoryTests pass, including the existing ones.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/HandleDirectory.swift OdeCore/Tests/OdeCoreTests/HandleDirectoryTests.swift
git commit -m "feat(core): contact photos and nicknames in HandleDirectory"
```

---

### Task 2: Contacts photos as avatars in the app

**Files:**
- Modify: `Ode/ContactsLoader.swift`
- Modify: `Ode/AppModel.swift` (`PersonHealth`, `analyze()`)
- Modify: `Ode/MainView.swift` (`Avatar` at ~line 346; sidebar row at ~line 295)
- Modify: `Ode/PersonHealthView.swift:66`
- Modify: `Ode/WaitingView.swift:52`
- Modify: `Ode/ChooseView.swift` (`ConversationRow` at ~line 151 and its call site at ~line 93)

**Interfaces:**
- Consumes: `HandleDirectory.Entry.init(name:phones:emails:nickname:photo:)`, `HandleDirectory.photo(for: Conversation)` (Task 1).
- Produces: `PersonHealth.photo: Data?`; `Avatar(title: String, photo: Data? = nil, size: CGFloat = 32)`.

- [ ] **Step 1: Fetch thumbnails and nicknames**

In `Ode/ContactsLoader.swift`, add two keys and pass them to the entry:

```swift
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
```

```swift
            entries.append(HandleDirectory.Entry(
                name: name,
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String },
                nickname: contact.nickname.isEmpty ? nil : contact.nickname,
                photo: contact.thumbnailImageData
            ))
```

- [ ] **Step 2: Carry the photo on PersonHealth**

In `Ode/AppModel.swift`, add to `PersonHealth` after `memberNames`:

```swift
    var photo: Data?
```

In `analyze()`, inside the `people = zip(conversations, health).map { ... }` closure, after the `PersonHealth(...)` line:

```swift
                    person.photo = names.photo(for: conversation)
```

- [ ] **Step 3: Draw the photo in Avatar**

Replace `struct Avatar` in `Ode/MainView.swift` with:

```swift
struct Avatar: View {
    let title: String
    var photo: Data? = nil
    var size: CGFloat = 32

    var body: some View {
        if let photo, let image = NSImage(data: photo) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.circle)
        } else {
            let letters = title.split(separator: " ").prefix(2).compactMap(\.first).filter(\.isLetter)
            Text(letters.isEmpty ? "#" : String(letters).uppercased())
                .font(.system(size: size * 0.375, weight: .medium))
                .frame(width: size, height: size)
                .background(Color(red: 0.914, green: 0.914, blue: 0.898), in: .circle)
        }
    }
}
```

If `MainView.swift` doesn't already `import AppKit`, `NSImage` is still available through SwiftUI on macOS; add `import AppKit` only if the build complains.

- [ ] **Step 4: Pass photos at every call site**

- `Ode/MainView.swift` (sidebar row): `Avatar(title: person.title, photo: person.photo, size: 32)`
- `Ode/PersonHealthView.swift:66`: `Avatar(title: person.title, photo: person.photo, size: 56)`
- `Ode/WaitingView.swift:52`: `Avatar(title: person.title, photo: person.photo, size: 36)`
- `Ode/ChooseView.swift`: add `let photo: Data?` to `ConversationRow` after `title`, use `Avatar(title: title, photo: photo, size: 32)` in its body, and at the call site pass it:

```swift
                        ConversationRow(conversation: conversation, title: picker.title(for: conversation),
                                        photo: picker.names.photo(for: conversation),
                                        isSelected: picker.isSelected(conversation)) {
```

- [ ] **Step 5: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Check it in the running app**

Run Ode from Xcode. Expected: people whose contact card has a photo show it as a round avatar in the sidebar, on the waiting list, in the person header, and on the "choose conversations" screen; people without one and group chats still show initials. If you're an agent without access to the GUI, say this step wasn't run.

- [ ] **Step 7: Commit**

```bash
git add Ode/ContactsLoader.swift Ode/AppModel.swift Ode/MainView.swift Ode/PersonHealthView.swift Ode/WaitingView.swift Ode/ChooseView.swift
git commit -m "feat(app): show Contacts photos as avatars"
```

---

### Task 3: Handoff, Kept and KeptDetector

**Files:**
- Create: `OdeCore/Sources/OdeCore/Kept.swift`
- Test: `OdeCore/Tests/OdeCoreTests/KeptDetectorTests.swift`

**Interfaces:**
- Consumes: `Message` (existing).
- Produces:
  - `public struct Handoff: Codable, Sendable, Equatable { public let conversationID: Int64; public let at: Date; public init(conversationID: Int64, at: Date) }`
  - `public struct Kept: Codable, Sendable, Equatable { public let conversationID: Int64; public let handoffAt: Date; public let sentAt: Date; public let messageID: Int64 }` with a public memberwise init.
  - `public enum KeptDetector` with `public static let window: TimeInterval = 86_400` and `public static func detect(handoffs: [Handoff], threads: [Int64: [Message]], now: Date = .now) -> (kept: [Kept], pending: [Handoff])`. `threads` maps conversation id to its messages in date order, as `AppModel.threads` keeps them.

- [ ] **Step 1: Write the failing tests**

Create `OdeCore/Tests/OdeCoreTests/KeptDetectorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeptDetectorTests`
Expected: compile failure, "cannot find 'Handoff' in scope".

- [ ] **Step 3: Implement**

Create `OdeCore/Sources/OdeCore/Kept.swift`:

```swift
import Foundation

/// The moment a reply left Ode for Messages.
public struct Handoff: Codable, Sendable, Equatable {
    public let conversationID: Int64
    public let at: Date

    public init(conversationID: Int64, at: Date) {
        self.conversationID = conversationID
        self.at = at
    }
}

/// A reply that started in Ode and that you then sent.
public struct Kept: Codable, Sendable, Equatable {
    public let conversationID: Int64
    public let handoffAt: Date
    public let sentAt: Date
    public let messageID: Int64

    public init(conversationID: Int64, handoffAt: Date, sentAt: Date, messageID: Int64) {
        self.conversationID = conversationID
        self.handoffAt = handoffAt
        self.sentAt = sentAt
        self.messageID = messageID
    }
}

public enum KeptDetector {
    public static let window: TimeInterval = 86_400

    /// Any message from you after the handoff counts, edited or not; a tapback is not a reply.
    public static func detect(handoffs: [Handoff], threads: [Int64: [Message]], now: Date = .now) -> (kept: [Kept], pending: [Handoff]) {
        var kept: [Kept] = []
        var pending: [Handoff] = []
        for handoff in handoffs {
            let deadline = handoff.at.addingTimeInterval(window)
            let sent = threads[handoff.conversationID]?.first {
                $0.isFromMe && $0.kind != .reaction && $0.date > handoff.at && $0.date <= deadline
            }
            if let sent {
                kept.append(Kept(conversationID: handoff.conversationID, handoffAt: handoff.at, sentAt: sent.date, messageID: sent.id))
            } else if now <= deadline {
                pending.append(handoff)
            }
        }
        return (kept, pending)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter KeptDetectorTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/Kept.swift OdeCore/Tests/OdeCoreTests/KeptDetectorTests.swift
git commit -m "feat(core): detect kept replies after a Messages handoff"
```

---

### Task 4: HandoffLog persistence

**Files:**
- Create: `OdeCore/Sources/OdeCore/HandoffLog.swift`
- Test: `OdeCore/Tests/OdeCoreTests/HandoffLogTests.swift`

**Interfaces:**
- Consumes: `Handoff`, `Kept` (Task 3).
- Produces: `public struct HandoffLog: Sendable` with
  - `public init(directory: URL)` (the directory is created on first write)
  - `public func pending() throws -> [Handoff]`
  - `public func record(_ handoff: Handoff) throws`: replaces any pending handoff for the same conversation
  - `public func replacePending(_ handoffs: [Handoff]) throws`
  - `public func kept() throws -> [Kept]`
  - `public func appendKept(_ new: [Kept]) throws`: throws without writing when the existing kept log can't be decoded
  - A missing file reads as empty.

- [ ] **Step 1: Write the failing tests**

Create `OdeCore/Tests/OdeCoreTests/HandoffLogTests.swift`:

```swift
import Foundation
import Testing
@testable import OdeCore

@Suite struct HandoffLogTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-log-\(UUID().uuidString)", isDirectory: true)
    var log: HandoffLog { HandoffLog(directory: directory) }
    let at = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func missingFilesReadAsEmpty() throws {
        #expect(try log.pending().isEmpty)
        #expect(try log.kept().isEmpty)
    }

    @Test func recordedHandoffsSurviveAReload() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.record(Handoff(conversationID: 8, at: at))
        #expect(try HandoffLog(directory: directory).pending() == [Handoff(conversationID: 7, at: at), Handoff(conversationID: 8, at: at)])
    }

    @Test func recordingAgainReplacesThePendingHandoff() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.record(Handoff(conversationID: 7, at: at.addingTimeInterval(600)))
        #expect(try log.pending() == [Handoff(conversationID: 7, at: at.addingTimeInterval(600))])
    }

    @Test func keptEventsAppend() throws {
        let first = Kept(conversationID: 7, handoffAt: at, sentAt: at.addingTimeInterval(60), messageID: 1)
        let second = Kept(conversationID: 8, handoffAt: at, sentAt: at.addingTimeInterval(90), messageID: 2)
        try log.appendKept([first])
        try log.appendKept([second])
        #expect(try log.kept() == [first, second])
    }

    @Test func replacePendingOverwrites() throws {
        try log.record(Handoff(conversationID: 7, at: at))
        try log.replacePending([])
        #expect(try log.pending().isEmpty)
    }

    @Test func aCorruptKeptLogIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("kept.json")
        try Data("not json".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            try log.appendKept([Kept(conversationID: 7, handoffAt: at, sentAt: at, messageID: 1)])
        }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HandoffLogTests`
Expected: compile failure, "cannot find 'HandoffLog' in scope".

- [ ] **Step 3: Implement**

Create `OdeCore/Sources/OdeCore/HandoffLog.swift`:

```swift
import Foundation

/// Pending handoffs and the append-only kept log, stored as JSON beside Ode's other data.
public struct HandoffLog: Sendable {
    private let pendingURL: URL
    private let keptURL: URL
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        pendingURL = directory.appendingPathComponent("handoffs.json")
        keptURL = directory.appendingPathComponent("kept.json")
    }

    public func pending() throws -> [Handoff] { try read(pendingURL) }

    public func record(_ handoff: Handoff) throws {
        let others = try pending().filter { $0.conversationID != handoff.conversationID }
        try write(others + [handoff], to: pendingURL)
    }

    public func replacePending(_ handoffs: [Handoff]) throws {
        try write(handoffs, to: pendingURL)
    }

    public func kept() throws -> [Kept] { try read(keptURL) }

    public func appendKept(_ new: [Kept]) throws {
        guard !new.isEmpty else { return }
        try write(try kept() + new, to: keptURL)
    }

    private func read<T: Decodable>(_ url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([T].self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
```

Note: ISO 8601 encoding drops sub-second precision. The tests use whole-second dates; `AppModel` (Task 5) rounds the handoff time down to the whole second for the same reason, so a reloaded handoff compares equal to the one recorded.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HandoffLogTests`
Expected: 6 tests pass.

- [ ] **Step 5: Run the whole suite**

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add OdeCore/Sources/OdeCore/HandoffLog.swift OdeCore/Tests/OdeCoreTests/HandoffLogTests.swift
git commit -m "feat(core): persist handoffs and the kept log"
```

---

### Task 5: Record handoffs and check for kept replies in the app

**Files:**
- Create: `Ode/MessagesHandoff.swift`
- Modify: `Ode/AppModel.swift` (new handoff section; calls at the end of `analyze()` and `syncOnce()`)
- Modify: `Ode/DraftComposerView.swift` (`copy(_:)` and `sendViaMessages()` at ~lines 443-460)

**Interfaces:**
- Consumes: `Handoff`, `KeptDetector.detect(handoffs:threads:now:)` (Task 3); `HandoffLog` (Task 4); `PersonHealth` (existing).
- Produces:
  - `enum MessagesHandoff { static func copy(_ text: String); static func open(_ person: PersonHealth) }`
  - `AppModel.handOff(_ person: PersonHealth, text: String, openMessages: Bool)`
  - `AppModel.checkKept()` (private)

- [ ] **Step 1: Extract MessagesHandoff**

Create `Ode/MessagesHandoff.swift`:

```swift
import AppKit
import OdeCore

/// The only way a reply leaves Ode: copied to the clipboard, with Messages opened to the thread. You press send.
enum MessagesHandoff {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ person: PersonHealth) {
        let participants = person.conversation.participants
        if !person.conversation.isGroup, participants.count == 1,
           let handle = participants[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "imessage:\(handle)") {
            NSWorkspace.shared.open(url)
        } else if let messagesApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.openApplication(at: messagesApp, configuration: .init())
        }
    }
}
```

- [ ] **Step 2: Add the handoff section to AppModel**

In `Ode/AppModel.swift`, next to `memoryPath` add:

```swift
    nonisolated private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ode", isDirectory: true)
    }

    private let handoffs = HandoffLog(directory: AppModel.supportDirectory)

    /// Records that a reply left Ode, so a send that follows counts as kept.
    func handOff(_ person: PersonHealth, text: String, openMessages: Bool) {
        MessagesHandoff.copy(text)
        if openMessages { MessagesHandoff.open(person) }
        let now = Date(timeIntervalSinceReferenceDate: Date.now.timeIntervalSinceReferenceDate.rounded(.down))
        try? handoffs.record(Handoff(conversationID: person.id, at: now))
    }

    private func checkKept() {
        guard let pending = try? handoffs.pending(), !pending.isEmpty else { return }
        let result = KeptDetector.detect(handoffs: pending, threads: threads)
        guard result.pending != pending else { return }
        do {
            try handoffs.appendKept(result.kept)
            try handoffs.replacePending(result.pending)
        } catch {
            return
        }
    }
```

The order in `checkKept()` matters: if appending to the kept log fails, the pending handoffs are left in place so the next check tries again rather than losing them.

- [ ] **Step 3: Check after load and after every sync**

In `analyze()`, after `judgePromises()` (the last line of the `do` block), add:

```swift
            checkKept()
```

In `syncOnce()`, after the final `judgePromises()`, add:

```swift
        checkKept()
```

- [ ] **Step 4: Use it from the composer**

In `Ode/DraftComposerView.swift`, replace `copy(_:)` and `sendViaMessages()` with:

```swift
    private func copy(_ text: String) {
        model.handOff(person, text: text, openMessages: false)
        copied = true
    }

    private func sendViaMessages() {
        guard let text = selectedText else { return }
        model.handOff(person, text: text, openMessages: true)
        copied = true
    }
```

If `import AppKit` in `DraftComposerView.swift` is no longer used by anything else in the file, leave it; removing it is out of scope.

- [ ] **Step 5: Build and run the core tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

Run: `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 6: Check it end to end**

1. Run Ode from Xcode, open someone's reply, and press "Send via Messages".
2. Run `cat ~/Library/Application\ Support/Ode/handoffs.json`. Expected: one entry with that conversation's id.
3. Send any text to that person in Messages (from the Mac or your phone). Within about 10 seconds:
4. Run `cat ~/Library/Application\ Support/Ode/kept.json`. Expected: one entry with that conversation id and the message's `sentAt`; `handoffs.json` is now `[]`.

If you're an agent without access to the GUI, say these steps weren't run.

- [ ] **Step 7: Commit**

```bash
git add Ode/MessagesHandoff.swift Ode/AppModel.swift Ode/DraftComposerView.swift
git commit -m "feat(app): log Messages handoffs and the replies you send"
```
