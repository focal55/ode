# Voice in the App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold Space anywhere in Ode, say "tell Maya I'm in for Saturday", let go, and land in Maya's composer with a draft in your own words. Hold Space again in the composer to change that draft by voice.

**Architecture:** OdeCore gains the last pure pieces: a speakable-people directory that keeps one conversation per name, a revision prompt, and a check for drafts that copy reported speech ("her mom") instead of speaking to the person. The app gains `VoiceCapture` (on-device `SpeechAnalyzer` push-to-talk), `VoiceDrafter` (the voice prompt through the same local-model route as drafting, with Apple's model as fallback), a "Your words" mode in `DraftComposerView`, and a key monitor plus `VoiceDock` overlay in `MainView` that routes each utterance through `VoiceIntent`. Ode speaking aloud and context suggestion chips are plan 2c.

**Tech Stack:** Swift 6, SwiftUI and AppKit (macOS 26), Speech (`SpeechAnalyzer`, `SpeechTranscriber`, `CaptureInputSequenceProvider`, `AssetInventory`), AVFoundation, FoundationModels, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (section "Voice"). Builds on `VoiceIntent`, `VoicePrompt` and `VoiceCheck` from `docs/superpowers/plans/2026-10-11-voice-core.md`.

## Global Constraints

- Push-to-talk: hold Space while no text field has focus. No global hotkey, no always-on listening.
- Microphone permission is requested on the first press, not at launch. Transcription is on-device; audio never leaves the Mac.
- After release, capture continues 300 ms so the last word isn't clipped.
- Voice keeps your words: the first draft from speech is one "YOUR WORDS" draft built with `VoicePrompt`. "Redraft" (⌘R) still produces Ode's three drafts.
- Everything said while the composer is open is an edit to the selected draft.
- When two conversations share a title, voice routes to the more recently active one.
- Failures: mic denied → the dock says "Mic is off. Type instead"; no match → "Who's it for?" with the transcript in the type box; ambiguous → buttons for each candidate.
- Ode never sends.
- Code style: no comments that restate code, conventional commits, no emojis.
- Commands: prefix Swift and Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Review Focus

1. Holding Space in any text field (search, the draft editor, the type box) must type a space and never start listening. The key monitor checks the first responder; checked manually in Task 5, step 4.
2. Letting go of Space while the speech model is still downloading or the mic is starting must not leave the mic on. `VoiceCapture.finish()` handles `.preparing`; checked manually in Task 5, step 4.
3. Two conversations titled the same must route to the more recently active one, not ask "Which Maya?". Covered by `theMostRecentConversationKeepsASharedName` in Task 1.
4. A spoken edit must revise the draft you selected, keeping your manual edits to it as the base. `revise` reads `selectedText`, which includes edits; checked manually in Task 5, step 4.
5. With LM Studio off, a voice draft must still appear, from Apple's model, with the existing on-device notice. `VoiceDrafter` falls back like `ReplyDrafter`; checked manually in Task 5, step 4.

---

### Task 1: Core: speakable people, revision prompt, reported-speech check

**Files:**
- Modify: `OdeCore/Sources/OdeCore/VoiceIntent.swift`
- Modify: `OdeCore/Sources/OdeCore/VoicePrompt.swift`
- Test: `OdeCore/Tests/OdeCoreTests/VoiceIntentTests.swift`, `OdeCore/Tests/OdeCoreTests/VoicePromptTests.swift`

**Interfaces:**
- Consumes: `VoiceIntent`, `VoicePrompt`, `VoiceCheck` (existing).
- Produces:
  - `public struct VoiceIntent.Candidate: Sendable { public init(id: Int64, title: String, nickname: String?, isGroup: Bool, lastActive: Date?) }`
  - `public static func VoiceIntent.people(from candidates: [Candidate]) -> [Person]`
  - `public static let VoicePrompt.revisionInstructions: String`
  - `public static func VoicePrompt.revision(messages: [Message], name: (String?) -> String, draft: String, instruction: String, isGroup: Bool) -> String`
  - `VoiceCheck.Problem.reportedSpeech`

- [ ] **Step 1: Write the failing tests**

Append to `VoiceIntentTests` (add `import Foundation` at the top of the file):

```swift
    @Test func theMostRecentConversationKeepsASharedName() {
        let people = VoiceIntent.people(from: [
            .init(id: 1, title: "Maya Chen", nickname: nil, isGroup: false, lastActive: Date(timeIntervalSince1970: 100)),
            .init(id: 2, title: "Sam Lee", nickname: nil, isGroup: false, lastActive: nil),
            .init(id: 18, title: "maya chen", nickname: nil, isGroup: false, lastActive: Date(timeIntervalSince1970: 200)),
        ])
        #expect(people.map(\.id) == [18, 2])
        #expect(VoiceIntent.parse("tell Maya Chen hi", people: people) == .reply(conversationID: 18, request: "hi"))
    }
```

Append to `VoicePromptTests`:

```swift
    @Test func revisionCarriesTheDraftAndTheChange() {
        let prompt = VoicePrompt.revision(messages: [], name: { _ in "Maya" }, draft: "I'm in for Saturday!",
                                          instruction: "make it shorter", isGroup: false)
        #expect(prompt.contains("Your draft: I'm in for Saturday!"))
        #expect(prompt.hasSuffix("Change You asked for: make it shorter"))
    }

    @Test func copiedReportedSpeechIsFlagged() {
        #expect(VoiceCheck.problems(request: "ask how her mom's doing", draft: "How is her mom doing?") == [.reportedSpeech])
        #expect(VoiceCheck.problems(request: "ask how her mom's doing", draft: "How's your mom doing?").isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter "VoiceIntentTests|VoicePromptTests" 2>&1 | grep -E "error:" | grep -v SwiftCompile | head -3`
Expected: errors that `people(from:)`, `revision` and `reportedSpeech` don't exist.

- [ ] **Step 3: Implement**

In `VoiceIntent.swift`, add inside `VoiceIntent`, after `Person`:

```swift
    public struct Candidate: Sendable {
        public let id: Int64
        public let title: String
        public let nickname: String?
        public let isGroup: Bool
        public let lastActive: Date?

        public init(id: Int64, title: String, nickname: String?, isGroup: Bool, lastActive: Date?) {
            self.id = id
            self.title = title
            self.nickname = nickname
            self.isGroup = isGroup
            self.lastActive = lastActive
        }
    }

    /// One speakable entry per name: when two conversations share a title, the more recent one answers to it.
    public static func people(from candidates: [Candidate]) -> [Person] {
        var chosen: [String: Candidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            let key = candidate.title.lowercased()
            if let existing = chosen[key] {
                if (candidate.lastActive ?? .distantPast) > (existing.lastActive ?? .distantPast) { chosen[key] = candidate }
            } else {
                chosen[key] = candidate
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }.map {
            Person(id: $0.id, names: Person.spokenNames(title: $0.title, nickname: $0.nickname, isGroup: $0.isGroup))
        }
    }
```

In `VoicePrompt.swift`, replace the body of `VoicePrompt.prompt` and add the revision prompt, sharing the conversation lines:

```swift
    public static let revisionInstructions = """
        You revise a text message You are about to send. Apply only the change You asked for and keep the rest as it is: \
        the same points, words and tone. Add nothing You didn't ask for. If the change asks to remove something, remove it.
        """

    public static func prompt(messages: [Message], name: (String?) -> String, request: String, isGroup: Bool) -> String {
        (conversation(messages, name: name, isGroup: isGroup) + ["What You said: \(request)"]).joined(separator: "\n")
    }

    public static func revision(messages: [Message], name: (String?) -> String, draft: String, instruction: String,
                                isGroup: Bool) -> String {
        (conversation(messages, name: name, isGroup: isGroup) + ["Your draft: \(draft)", "Change You asked for: \(instruction)"])
            .joined(separator: "\n")
    }

    private static func conversation(_ messages: [Message], name: (String?) -> String, isGroup: Bool) -> [String] {
        var lines = [isGroup ? "Group conversation:" : "Conversation:"]
        lines += messages.filter { $0.kind == .text && $0.text != nil }.suffix(8).map { message in
            "\(message.isFromMe ? "You" : name(message.sender)): \(message.text!.prefix(280))"
        }
        if let style = WritingStyle(of: messages).summary { lines.append(style) }
        return lines
    }
```

In `VoiceCheck`, add `case reportedSpeech` to `Problem` (after `addedNumber`), add the set:

```swift
    private static let reportedPronouns: Set<String> = ["her", "his", "him", "she", "he", "shes", "hes"]
```

and in `problems(request:draft:)`, right after the `addedNumber` loop:

```swift
        // "ask how her mom is" sent to her should say "your mom"; copying "her mom" talks about her, not to her.
        let draftPairs = Set(zip(written, written.dropFirst()).map { "\($0) \(stem($1))" })
        if zip(spoken, spoken.dropFirst()).contains(where: { reportedPronouns.contains($0) && draftPairs.contains("\($0) \(stem($1))") }) {
            problems.append(.reportedSpeech)
        }
```

- [ ] **Step 4: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore 2>&1 | grep -E "✘ Test .*failed|Test run" | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add OdeCore/Sources/OdeCore/VoiceIntent.swift OdeCore/Sources/OdeCore/VoicePrompt.swift OdeCore/Tests/OdeCoreTests/VoiceIntentTests.swift OdeCore/Tests/OdeCoreTests/VoicePromptTests.swift
git commit -m "feat(core): one speakable conversation per name, voice revisions, and a reported-speech check"
```

---

### Task 2: VoiceDrafter and the model hooks

**Files:**
- Create: `Ode/VoiceDrafter.swift`
- Modify: `Ode/AppModel.swift` (next to `draftReply`, ~line 406)

**Interfaces:**
- Consumes: `VoicePrompt.prompt/revision/instructions/revisionInstructions/schema/Answer`, `VoiceIntent.Candidate`, `VoiceIntent.people(from:)` (Task 1); `CloudRequest`, `CloudRunner`, `Draft`, `DraftResult`, `HandleDirectory.nickname(for:)` (existing).
- Produces:
  - `enum VoiceDrafter { static func draft(instructions: String, prompt: String, cloud: CloudRunner?) async -> DraftResult? }`, which returns one `Draft` labelled `"YOUR WORDS"`.
  - `AppModel.voicePeople: [VoiceIntent.Person]`
  - `AppModel.voiceDraft(for: PersonHealth, request: String) async -> DraftResult?`
  - `AppModel.voiceRevision(for: PersonHealth, draft: String, instruction: String) async -> DraftResult?`

- [ ] **Step 1: Write VoiceDrafter**

Create `Ode/VoiceDrafter.swift`:

```swift
import Foundation
import FoundationModels
import OdeCore

@Generable
struct VoiceDraft {
    @Guide(description: "The message You will send, and nothing else.")
    var text: String
}

/// Your spoken words as the message you'd send, through the drafting model, falling back to Apple's.
enum VoiceDrafter {
    static let label = "YOUR WORDS"

    static func draft(instructions: String, prompt: String, cloud: CloudRunner?) async -> DraftResult? {
        if let cloud, let data = await cloud(CloudRequest(system: instructions, prompt: prompt, schemaName: "voice",
                                                          schema: VoicePrompt.schema)),
           let answer = try? JSONDecoder().decode(VoicePrompt.Answer.self, from: data) {
            return .drafts([Draft(label: label, text: answer.text, why: "From what you said")], onDevice: false)
        }
        guard !Task.isCancelled else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return .unavailable }
        let session = LanguageModelSession(instructions: instructions)
        guard let answer = try? await session.respond(to: prompt, generating: VoiceDraft.self).content else {
            return Task.isCancelled ? nil : .blocked
        }
        return .drafts([Draft(label: label, text: answer.text, why: "From what you said")], onDevice: true)
    }
}
```

- [ ] **Step 2: Add the model hooks**

In `Ode/AppModel.swift`, after `draftReply(...)`:

```swift
    var voicePeople: [VoiceIntent.Person] {
        VoiceIntent.people(from: people.map { person in
            let nickname = person.conversation.isGroup ? nil
                : person.conversation.participants.lazy.compactMap { self.picker.names.nickname(for: $0) }.first
            return VoiceIntent.Candidate(id: person.id, title: person.title, nickname: nickname,
                                         isGroup: person.conversation.isGroup, lastActive: person.conversation.lastMessageDate)
        })
    }

    func voiceDraft(for person: PersonHealth, request: String) async -> DraftResult? {
        let prompt = VoicePrompt.prompt(messages: threads[person.id] ?? [], name: speakerName(for: person), request: request,
                                        isGroup: person.conversation.isGroup)
        return await VoiceDrafter.draft(instructions: VoicePrompt.instructions, prompt: prompt, cloud: cloud(.drafting, person))
    }

    func voiceRevision(for person: PersonHealth, draft: String, instruction: String) async -> DraftResult? {
        let prompt = VoicePrompt.revision(messages: threads[person.id] ?? [], name: speakerName(for: person), draft: draft,
                                          instruction: instruction, isGroup: person.conversation.isGroup)
        return await VoiceDrafter.draft(instructions: VoicePrompt.revisionInstructions, prompt: prompt,
                                        cloud: cloud(.drafting, person))
    }
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Ode/VoiceDrafter.swift Ode/AppModel.swift
git commit -m "feat(app): draft from your spoken words through the local model"
```

---

### Task 3: "Your words" in the composer

**Files:**
- Modify: `Ode/DraftComposerView.swift` (properties ~line 8-30; `.task` ~line 70; title ~line 136; `generate()` ~line 374)
- Modify: `Ode/MainView.swift` (`DraftRequest` ~line 25; the `DraftComposerView(...)` call ~line 53)

**Interfaces:**
- Consumes: `AppModel.voiceDraft`, `AppModel.voiceRevision`, `VoiceDrafter.label` (Task 2).
- Produces:
  - `MainView.DraftRequest.spoken: String` (default `""`)
  - `DraftComposerView` params `var spoken = ""`, `var edit: String? = nil`, `var editHandled: () -> Void = {}`
  - `MainView` state `pendingEdit: String?`, set by Task 5.

- [ ] **Step 1: Carry the spoken request**

In `MainView.DraftRequest`, add `var spoken = ""` after `steer`. In `MainView`, add `@State private var pendingEdit: String?`, and change the composer call to:

```swift
                    DraftComposerView(model: model, person: request.person, close: { draftRequest = nil }, steer: request.steer,
                                      spoken: request.spoken, edit: pendingEdit, editHandled: { pendingEdit = nil })
                        .id(request.id)
```

- [ ] **Step 2: Draft from your words, and revise by voice**

In `DraftComposerView`, add after `var initialResult: DraftResult?`:

```swift
    var spoken = ""
    var edit: String?
    var editHandled: () -> Void = {}
```

and a computed property next to `drafts`:

```swift
    private var inYourWords: Bool { drafts.first?.label == VoiceDrafter.label }
```

In `.task`, make the spoken path come first:

```swift
            if !spoken.isEmpty {
                start(.all) { await model.voiceDraft(for: person, request: spoken) }
            } else if let initialResult {
```

(the rest of the existing `if`/`else if` chain stays as it is). Add after `.onDisappear { task?.cancel() }`:

```swift
        .onChange(of: edit) { _, instruction in
            guard let instruction else { return }
            editHandled()
            revise(instruction)
        }
```

Change the title `Text("Three ways to say it")` to `Text(inYourWords ? "In your words" : "Three ways to say it")`.

In `generate()`, use your spoken words as the steer when you didn't type one:

```swift
        let steerText = steer.trimmingCharacters(in: .whitespaces).isEmpty ? spoken : steer.trimmingCharacters(in: .whitespaces)
        start(.all) {
            await model.draftReply(for: person, steer: steerText, length: length, avoid: avoid)
        }
```

Add after `reroll(_:)`:

```swift
    private func revise(_ instruction: String) {
        guard work == nil, let base = selectedText else { return }
        start(.all) { await model.voiceRevision(for: person, draft: base, instruction: instruction) }
    }
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Ode/DraftComposerView.swift Ode/MainView.swift
git commit -m "feat(app): an \"in your words\" draft and spoken edits in the composer"
```

---

### Task 4: Microphone permission and VoiceCapture

**Files:**
- Modify: `Ode.xcodeproj/project.pbxproj` (both build configurations of the Ode target, next to `INFOPLIST_KEY_NSContactsUsageDescription`)
- Create: `Ode/VoiceCapture.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `@MainActor @Observable final class VoiceCapture` with `enum State { idle, preparing, listening, finishing, denied, unavailable }`, `private(set) var state`, `private(set) var transcript: String`, `func start() async`, `func finish() async -> String`.

- [ ] **Step 1: Permission and entitlement**

In `Ode.xcodeproj/project.pbxproj`, in both places where `INFOPLIST_KEY_NSContactsUsageDescription` appears for the Ode target, add these two lines right after it:

```
				INFOPLIST_KEY_NSMicrophoneUsageDescription = "Ode listens only while you hold Space, and turns what you say into a draft on this Mac. Audio never leaves it.";
				ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES;
```

The app runs with the hardened runtime and no sandbox. Without `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT`, the `com.apple.security.device.audio-input` entitlement is missing and the microphone delivers silence without an error.

- [ ] **Step 2: Write VoiceCapture**

Create `Ode/VoiceCapture.swift`:

```swift
import AVFoundation
import Observation
import Speech

/// Push-to-talk transcription, entirely on this Mac: `start` when Space goes down, `finish` when it comes up.
@MainActor @Observable
final class VoiceCapture {
    enum State: Equatable { case idle, preparing, listening, finishing, denied, unavailable }

    private(set) var state = State.idle
    private(set) var transcript = ""
    private var finalized = ""
    private var released = false
    private var analyzer: SpeechAnalyzer?
    private var session: AVCaptureSession?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var feeding: Task<Void, Never>?
    private var reading: Task<Void, Never>?

    func start() async {
        guard [.idle, .denied, .unavailable].contains(state) else { return }
        transcript = ""
        finalized = ""
        released = false
        guard await AVCaptureDevice.requestAccess(for: .audio) else { state = .denied; return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              let device = AVCaptureDevice.default(for: .audio) else { state = .unavailable; return }
        state = .preparing
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            let provider = try await CaptureInputSequenceProvider.providerWithSession(from: device, compatibleWith: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            reading = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal { finalized += text }
                        transcript = (finalized + (result.isFinal ? "" : text)).trimmingCharacters(in: .whitespaces)
                    }
                } catch {}
            }
            // Our own stream, so letting go of Space can end the input without tearing down the provider mid-buffer.
            feeding = Task {
                do { for try await item in provider.analyzerInputs { continuation.yield(item) } } catch {}
            }
            provider.captureSession.startRunning()
            (self.analyzer, session, input) = (analyzer, provider.captureSession, continuation)
            state = .listening
            if released { _ = await finish() }
        } catch {
            state = .unavailable
        }
    }

    /// The final transcript, or "" if nothing was heard or the mic never started.
    func finish() async -> String {
        switch state {
        case .preparing:
            released = true
            return ""
        case .listening:
            break
        default:
            return ""
        }
        state = .finishing
        try? await Task.sleep(for: .milliseconds(300))
        session?.stopRunning()
        feeding?.cancel()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reading?.value
        (analyzer, session, input, feeding, reading) = (nil, nil, nil, nil, nil)
        state = .idle
        return transcript
    }
}
```

If Swift 6 strict concurrency rejects capturing `provider` or `transcriber` in the tasks, or `startRunning()` on the main actor, make the smallest change that compiles: keep the tasks on the main actor as written, and if needed move `startRunning()` into `Task.detached` with the session captured as `nonisolated(unsafe) let`. Record what you changed as a ruling.

- [ ] **Step 3: Build and check the entitlement**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

Run: `codesign -d --entitlements - "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Ode.app" 2>&1 | grep -c audio-input`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add Ode.xcodeproj/project.pbxproj Ode/VoiceCapture.swift
git commit -m "feat(app): on-device push-to-talk transcription"
```

---

### Task 5: Push-to-talk, the voice dock, and routing

**Files:**
- Create: `Ode/VoiceDock.swift`
- Modify: `Ode/MainView.swift`

**Interfaces:**
- Consumes: `VoiceCapture` (Task 4); `AppModel.voicePeople` (Task 2); `DraftRequest.spoken`, `pendingEdit` (Task 3); `VoiceIntent.parse` (core).
- Produces: `struct VoiceDock: View`; `enum VoiceNotice: Equatable { case whoFor, which([PersonHealth], String), micOff, unavailable, allCaughtUp }`.

- [ ] **Step 1: Write the dock**

Create `Ode/VoiceDock.swift`:

```swift
import SwiftUI

enum VoiceNotice: Equatable {
    case whoFor
    case which([PersonHealth], String)
    case micOff
    case unavailable
    case allCaughtUp
}

/// What you're saying while you hold Space, and what Ode needs from you when it couldn't route it.
struct VoiceDock: View {
    let capture: VoiceCapture
    let notice: VoiceNotice?
    @Binding var typed: String
    let submit: (String) -> Void
    let choose: (PersonHealth, String) -> Void

    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 10) {
            if capture.state == .listening || capture.state == .finishing || capture.state == .preparing {
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                        .opacity(capture.state == .listening ? 1 : 0.4)
                    Text(capture.transcript.isEmpty ? (capture.state == .preparing ? "Getting ready…" : "Listening…") : capture.transcript)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(3)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: .capsule)
            }
            if let notice { noticeView(notice) }
            HStack(spacing: 8) {
                TextField("Hold Space to talk, or type: \"tell Maya I'm in\"", text: $typed)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit { submit(typed) }
                    .frame(width: 360)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
        }
        .padding(.bottom, 20)
        .onChange(of: notice) { _, notice in if notice == .whoFor { typing = true } }
    }

    @ViewBuilder private func noticeView(_ notice: VoiceNotice) -> some View {
        HStack(spacing: 8) {
            switch notice {
            case .whoFor: Text("Who's it for? Fix the name below and press Return.")
            case .micOff: Text("Mic is off. Type instead, or allow Ode in System Settings › Privacy › Microphone.")
            case .unavailable: Text("Voice isn't available on this Mac right now. Type instead.")
            case .allCaughtUp: Text("Nobody's waiting on you.")
            case .which(let people, let request):
                Text("Which one?")
                ForEach(people) { person in
                    Button(person.title) { choose(person, request) }
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }
}
```

- [ ] **Step 2: Route utterances in MainView**

In `Ode/MainView.swift`, add state:

```swift
    @State private var capture = VoiceCapture()
    @State private var notice: VoiceNotice?
    @State private var typed = ""
    @State private var keyMonitor: Any?
```

Add the dock as an overlay on the `HStack` that holds the sidebar and center pane (the one under `topBar`), and install the key monitor:

```swift
            .overlay(alignment: .bottom) {
                VoiceDock(capture: capture, notice: notice, typed: $typed, submit: { route($0) }) { person, request in
                    notice = nil
                    draftRequest = DraftRequest(person: person, steer: "", spoken: request)
                }
            }
            .onAppear { installPushToTalk() }
            .onDisappear { keyMonitor.map(NSEvent.removeMonitor) }
```

Add these methods to `MainView`:

```swift
    /// Space held anywhere outside a text field talks to Ode; in a text field it's just a space.
    private func installPushToTalk() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            if event.type == .keyDown, !event.isARepeat {
                notice = nil
                Task { await capture.start() }
            } else if event.type == .keyUp {
                Task {
                    let heard = await capture.finish()
                    switch capture.state {
                    case .denied: notice = .micOff
                    case .unavailable: notice = .unavailable
                    default: if !heard.isEmpty { route(heard) }
                    }
                }
            }
            return nil
        }
    }

    private func route(_ text: String) {
        typed = ""
        notice = nil
        switch VoiceIntent.parse(text, people: model.voicePeople, focused: draftRequest?.person.id) {
        case .reply(let id, let request):
            guard let person = model.people.first(where: { $0.id == id }) else { return }
            draftRequest = DraftRequest(person: person, steer: "", spoken: request)
        case .ambiguous(let ids, let request):
            notice = .which(model.people.filter { ids.contains($0.id) }, request)
        case .edit(let instruction):
            pendingEdit = instruction
        case .ask:
            guard let item = model.waiting.first, let person = model.people.first(where: { $0.id == item.conversationID }) else {
                notice = .allCaughtUp
                return
            }
            draftRequest = DraftRequest(person: person, steer: item.steer)
        case .unknown(let heard):
            typed = heard
            notice = .whoFor
        }
    }
```

`PersonHealth` must be `Identifiable` and `Equatable` for `ForEach` and `VoiceNotice: Equatable`; it already is both.

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build 2>&1 | grep -E ' error: |\*\* BUILD'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Check it in the running app (Joe)**

Run Ode from Xcode and check, in order:
1. Hold Space on the waiting list: a mic permission prompt appears the first time; allow it. Say "tell <someone you track> I'm running late", let go. The composer opens for them titled "In your words" with your words as the draft.
2. Hold Space in the composer, say "make it shorter", let go: the draft is revised.
3. ⌘R: three normal drafts appear.
4. Click in the search field and hold Space: spaces are typed, nothing listens.
5. Say "tell Bob hi" (someone you don't track): "Who's it for?" appears with the text in the type box.
6. Type "text <someone> hi" in the dock and press Return: their composer opens.
7. Quit LM Studio and repeat 1: a draft still appears with the on-device notice.
8. Tap Space quickly (press and release at once) the very first time, before the speech model is installed: nothing stays listening.

If you're an agent without access to the GUI, say these steps weren't run.

- [ ] **Step 5: Run the suite and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore 2>&1 | tail -1`
Expected: all tests pass.

```bash
git add Ode/VoiceDock.swift Ode/MainView.swift
git commit -m "feat(app): hold Space to tell Ode who to reply to and what to say"
```
