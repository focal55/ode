import Foundation
import OdeCore
import Observation

struct PersonHealth: Identifiable, Equatable {
    enum Health: Equatable {
        case person(RelationshipMetrics)
        case group(GroupMetrics)
    }

    let conversation: Conversation
    let title: String
    var health: Health
    /// Group members' handles to contact names.
    var memberNames: [String: String] = [:]
    var id: Int64 { conversation.id }

    var messageCount: Int {
        switch health {
        case .person(let metrics): metrics.messageCount
        case .group(let metrics): metrics.messageCount
        }
    }

    var needsAttention: Bool {
        switch health {
        case .person(let metrics): metrics.observations().contains(where: \.isActionable)
        case .group(let metrics):
            metrics.observations.contains {
                switch $0 {
                case .drifting, .goneQuiet: true
                case .carries: false
                }
            }
        }
    }

    nonisolated static func health(for conversation: Conversation, messages: [Message]) -> Health {
        conversation.isGroup
            ? .group(GroupMetrics.compute(messages, participants: conversation.participants))
            : .person(RelationshipMetrics.compute(messages))
    }

    func memberName(_ handle: String?) -> String {
        handle.map { memberNames[$0] ?? $0 } ?? "You"
    }
}

enum Relationship: String, CaseIterable, Identifiable {
    case family = "Family"
    case friend = "Friend"
    case work = "Work"
    var id: Self { self }
}

struct MemoryResult: Identifiable, Equatable {
    let moment: Moment
    let title: String
    var score: Float = 0
    var id: String { moment.id }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case checking
        case connect(MessagesAccess)
        case loading
        case choose
        case analyzing
        case health
        case failed(String)
    }

    private static let selectionKey = "selectedChatIDs"
    private static let labelsKey = "relationshipLabels"
    private static let pinnedKey = "pinnedConversations"
    private static let dismissedKey = "dismissedWaiting"

    private(set) var labels: [Int64: Relationship] = {
        let stored = UserDefaults.standard.dictionary(forKey: AppModel.labelsKey) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            Int64(key).flatMap { id in Relationship(rawValue: value).map { (id, $0) } }
        })
    }()
    private(set) var pinned = Set((UserDefaults.standard.array(forKey: AppModel.pinnedKey) as? [Int] ?? []).map(Int64.init))
    private(set) var dismissedWaiting: [Int64: Int64] = (UserDefaults.standard.dictionary(forKey: AppModel.dismissedKey) as? [String: Int] ?? [:])
        .reduce(into: [:]) { result, entry in
            if let id = Int64(entry.key) { result[id] = Int64(entry.value) }
        }
    private(set) var checkingPromises = false

    func setLabel(_ label: Relationship?, for id: Int64) {
        labels[id] = label
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: labels.map { (String($0.key), $0.value.rawValue) }), forKey: Self.labelsKey)
    }

    func togglePin(_ id: Int64) {
        if pinned.remove(id) == nil { pinned.insert(id) }
        UserDefaults.standard.set(pinned.map(Int.init), forKey: Self.pinnedKey)
    }

    func since(_ person: PersonHealth) -> Date? {
        threads[person.id]?.first?.date
    }

    func lastMessage(_ person: PersonHealth) -> Message? {
        threads[person.id]?.last { $0.kind == .text || $0.kind == .attachmentOnly }
    }

    /// The Lens looks at the last ninety days.
    func lensMetrics(for person: PersonHealth) -> RelationshipMetrics {
        let cutoff = Date.now.addingTimeInterval(-RelationshipMetrics.recentWindow)
        return RelationshipMetrics.compute((threads[person.id] ?? []).filter { $0.date >= cutoff })
    }

    func temperature(for person: PersonHealth) -> Temperature {
        Temperature(of: threads[person.id] ?? [])
    }

    private var topicsCache: [Int64: [String]] = [:]
    private var remindersCache: [Int64: [Reminder]] = [:]

    func reminders(for person: PersonHealth) async -> [Reminder] {
        if let cached = remindersCache[person.id] { return cached }
        let found = await ReminderExtractor.reminders(in: threads[person.id] ?? [], name: speakerName(for: person),
                                                      cloud: cloud(.deepAnalysis, person))
        remindersCache[person.id] = found
        return found
    }

    func patterns(for person: PersonHealth) -> [Patterns.Pattern] {
        Patterns.find(in: threads[person.id] ?? [])
    }

    func topics(for person: PersonHealth) async -> [String] {
        if let cached = topicsCache[person.id] { return cached }
        let name = speakerName(for: person)
        let topics = await TopicExtractor.topics(in: threads[person.id] ?? [], name: name, cloud: cloud(.deepAnalysis, person))
        topicsCache[person.id] = topics
        return topics
    }

    /// The best older moment with this person that relates to what was just said.
    private var recalledCache: [Int64: MemoryResult] = [:]

    func recalled(for person: PersonHealth) async -> MemoryResult? {
        if let cached = recalledCache[person.id] { return cached }
        guard memoryEnabled else { return nil }
        let recentText = (threads[person.id] ?? []).suffix(6).compactMap(\.text).joined(separator: " ")
        guard !recentText.isEmpty else { return nil }
        let id = person.id
        let cutoff = Date.now.addingTimeInterval(-14 * 86_400)
        let hit = await Task.detached { () -> MemoryIndex.Hit? in
            guard let memory = Self.openMemory() else { return nil }
            return try? memory.index.search(recentText, embedder: memory.embedder, limit: 1, conversationID: id, endingBefore: cutoff).first
        }.value
        return hit.map { MemoryResult(moment: $0.moment, title: person.title, score: $0.score) }
    }

    func searchMemory(_ text: String, in person: PersonHealth) async -> [MemoryResult] {
        guard memoryEnabled else { return [] }
        let id = person.id
        let hits = await Task.detached { () -> [MemoryIndex.Hit] in
            guard let memory = Self.openMemory() else { return [] }
            return (try? memory.index.search(text, embedder: memory.embedder, limit: 30, conversationID: id)) ?? []
        }.value
        return hits.map { MemoryResult(moment: $0.moment, title: person.title, score: $0.score) }
    }

    func speakerName(for person: PersonHealth) -> (String?) -> String {
        let isGroup = person.conversation.isGroup
        return { handle in
            guard let handle else { return "You" }
            return person.memberNames[handle] ?? (isGroup ? handle : person.title)
        }
    }

    let ai = AISettings()

    private func cloud(_ job: AIJob, _ person: PersonHealth) -> CloudRunner? {
        ai.runner(for: job, conversationID: person.id, title: person.title, label: labels[person.id])
    }

    private(set) var phase = Phase.checking
    private(set) var people: [PersonHealth] = []
    var picker = ConversationPicker(chats: [])
    private var polling: Task<Void, Never>?

    func start() {
        guard polling == nil else { return }
        polling = Task {
            while !Task.isCancelled {
                let access = await Task.detached { MessagesAccess.check() }.value
                if access == .granted {
                    await loadChats()
                    return
                }
                phase = .connect(access)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func importSelected() {
        UserDefaults.standard.set(picker.selected.map(Int.init), forKey: Self.selectionKey)
        Task { await analyze() }
    }

    func changeConversations() {
        syncing?.cancel()
        indexing?.cancel()
        phase = .choose
    }

    var canReturnToHealth: Bool { !people.isEmpty }

    func returnToHealth() {
        phase = .health
        startSyncing()
    }

    private static let liveSyncKey = "liveSyncEnabled"

    var liveSyncEnabled = UserDefaults.standard.object(forKey: AppModel.liveSyncKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveSyncEnabled, forKey: Self.liveSyncKey)
            if !liveSyncEnabled { syncing?.cancel() }
        }
    }

    /// Every message of every chosen conversation, oldest first, kept current by live sync.
    private(set) var threads: [Int64: [Message]] = [:]
    private var loops: [Int64: OpenLoops] = [:]
    private var loopGeneration: [Int64: Int] = [:]
    private var judging: [Int64: (generation: Int, task: Task<(OpenLoops, [String: OpenLoopJudge.Verdict]), Never>)] = [:]
    private var verdicts: [Int64: [String: OpenLoopJudge.Verdict]] = [:]
    private var cursor: Int64 = 0
    private var syncing: Task<Void, Never>?
    private static let memoryEnabledKey = "memoryEnabled"

    /// Off deletes the memory file; on rebuilds it from the chosen conversations.
    var memoryEnabled = UserDefaults.standard.object(forKey: AppModel.memoryEnabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(memoryEnabled, forKey: Self.memoryEnabledKey)
            if memoryEnabled {
                updateMemory(for: people)
            } else {
                let pending = indexing
                pending?.cancel()
                indexingProgress = nil
                let path = Self.memoryPath
                // A batch already writing finishes before cancellation is seen; delete only after it.
                indexing = Task {
                    await pending?.value
                    await Task.detached {
                        for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
                    }.value
                }
            }
        }
    }

    /// Fraction of chosen conversations indexed into memory; nil when idle.
    private(set) var indexingProgress: Double?
    private var indexing: Task<Void, Never>?

    nonisolated private static var memoryPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Ode/memory.sqlite").path
    }

    /// Prefers the bundled MiniLM model and falls back to Apple's. The index is opened with the
    /// chosen model's id, which clears it whenever the model changes.
    nonisolated private static func openMemory() -> (index: MemoryIndex, embedder: any Embedder)? {
        let embedder: any Embedder
        let id: String
        if let url = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc"),
           let model = try? SentenceModelEmbedder(compiledModelAt: url) {
            (embedder, id) = (model, SentenceModelEmbedder.id)
        } else if let apple = ContextualEmbedder() {
            (embedder, id) = (apple, "apple-contextual")
        } else {
            return nil
        }
        guard let index = try? MemoryIndex(path: memoryPath, embedderID: id) else { return nil }
        return (index, embedder)
    }

    func searchMemory(_ text: String) async -> [MemoryResult] {
        guard memoryEnabled else { return [] }
        let titles = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.title) })
        let hits = await Task.detached { () -> [MemoryIndex.Hit] in
            guard let memory = Self.openMemory() else { return [] }
            return (try? memory.index.search(text, embedder: memory.embedder, limit: 30)) ?? []
        }.value
        return hits.compactMap { hit in
            titles[hit.moment.conversationID].map { MemoryResult(moment: hit.moment, title: $0, score: hit.score) }
        }
    }

    /// Adds closed sessions not yet in memory. Safe to call repeatedly: each conversation
    /// resumes after the last message already indexed.
    private func updateMemory(for targets: [PersonHealth]) {
        guard memoryEnabled else { return }
        let previous = indexing
        let jobs = targets.map { person in
            (person.id, threads[person.id] ?? [], person.title, person.memberNames)
        }
        indexing = Task {
            await previous?.value
            for (offset, job) in jobs.enumerated() {
                guard !Task.isCancelled else { return }
                if jobs.count > 1 { indexingProgress = Double(offset) / Double(jobs.count) }
                let (id, messages, title, memberNames) = job
                await Task.detached(priority: .utility) {
                    guard let (index, embedder) = Self.openMemory(),
                          let through = try? index.indexedThrough(conversationID: id) else { return }
                    let pending = messages.filter { $0.id > through }
                    let moments = Moment.split(pending, conversationID: id) { handle in
                        handle.map { memberNames[$0] ?? title } ?? "You"
                    }
                    for batch in stride(from: 0, to: moments.count, by: 200) {
                        try? index.add(Array(moments[batch..<min(batch + 200, moments.count)]), embedder: embedder)
                    }
                }.value
            }
            indexingProgress = nil
        }
    }

    func confirmedLoops(for person: PersonHealth) -> [OpenLoop] {
        if case .judged(let items) = loops[person.id] { return items.filter(\.isConfirmed) }
        return []
    }

    /// The home list: who is waiting to hear from you, most urgent first.
    var waiting: [Waiting] {
        let items = people.flatMap { person -> [Waiting] in
            let thread = threads[person.id] ?? []
            let newest = Waiting.newestSpokenID(in: thread)
            var found = confirmedLoops(for: person).map {
                Waiting.promised(in: person.conversation, task: $0.task, made: $0.date, newestMessageID: newest)
            }
            if let unanswered = Waiting.unanswered(in: person.conversation, messages: thread) { found.append(unanswered) }
            if case .person(let metrics) = person.health,
               let quiet = Waiting.quiet(in: person.conversation, metrics: metrics, newestMessageID: newest) {
                found.append(quiet)
            }
            return found
        }
        return Waiting.rank(items, dismissed: dismissedWaiting)
    }

    func dismiss(_ item: Waiting) {
        dismissedWaiting[item.conversationID] = item.newestMessageID
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: dismissedWaiting.map { (String($0.key), Int($0.value)) }),
                                  forKey: Self.dismissedKey)
    }

    /// Judges open loops for everyone not judged yet, so promises reach the home list without opening each person.
    /// Only on device: people whose quick reads go to a cloud model are judged when you open them, which is
    /// where the consent prompt belongs.
    private func judgePromises() {
        guard !checkingPromises else { return }
        checkingPromises = true
        Task {
            while let person = people.first(where: {
                loops[$0.id] == nil && ai.route(for: .quickReads, label: labels[$0.id]).provider == .onDevice
            }) {
                _ = await openLoops(for: person, cloud: nil)
            }
            checkingPromises = false
        }
    }

    func draftReply(for person: PersonHealth, steer: String, length: DraftLength, avoid: [String] = []) async -> DraftResult? {
        await ReplyDrafter.draft(messages: threads[person.id] ?? [], name: speakerName(for: person),
                                 openLoops: confirmedLoops(for: person).map(\.task), steer: steer, length: length,
                                 isGroup: person.conversation.isGroup, avoid: avoid, cloud: cloud(.drafting, person))
    }

    func draftingRoute(for person: PersonHealth) -> Route {
        ai.route(for: .drafting, label: labels[person.id])
    }

    func openLoops(for person: PersonHealth) async -> OpenLoops {
        await openLoops(for: person, cloud: cloud(.quickReads, person))
    }

    /// One judging run per person at a time. A run that started before new messages arrived is
    /// discarded, and verdicts for excerpts that didn't change are reused rather than judged again.
    private func openLoops(for person: PersonHealth, cloud runner: CloudRunner?) async -> OpenLoops {
        if let cached = loops[person.id] { return cached }
        let generation = loopGeneration[person.id, default: 0]
        if let running = judging[person.id], running.generation == generation { return await running.task.value.0 }
        let candidates = OpenLoopCandidate.find(in: threads[person.id] ?? [])
        let isGroup = person.conversation.isGroup
        let known = verdicts[person.id] ?? [:]
        let task = Task {
            await OpenLoopJudge.evaluate(candidates, name: { handle in
                guard let handle else { return "You" }
                return person.memberNames[handle] ?? (isGroup ? handle : person.title)
            }, cloud: runner, known: known)
        }
        judging[person.id] = (generation, task)
        let (result, judged) = await task.value
        if loopGeneration[person.id, default: 0] == generation {
            loops[person.id] = result
            verdicts[person.id] = judged
            judging[person.id] = nil
        }
        return result
    }

    private func invalidateLoops(_ id: Int64) {
        loops[id] = nil
        loopGeneration[id, default: 0] += 1
    }

    private func loadChats() async {
        phase = .loading
        do {
            let chats = try await Task.detached { try MessagesStore().chats() }.value
            picker = ConversationPicker(chats: chats)
            picker.names = await ContactsLoader.directory()
            if let saved = UserDefaults.standard.array(forKey: Self.selectionKey) as? [Int], !saved.isEmpty {
                picker.restore(selection: Set(saved.map(Int64.init)))
                await analyze()
            } else {
                phase = .choose
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func analyze() async {
        syncing?.cancel()
        phase = .analyzing
        let conversations = picker.selectedConversations
        do {
            let (latest, loaded) = try await Task.detached { () throws -> (Int64, [[Message]]) in
                let store = try MessagesStore()
                // Read the cursor first: anything arriving mid-load is fetched again by sync and deduplicated.
                let latest = try store.latestRowID()
                let threads = try conversations.map { conversation in
                    try conversation.chatIDs.flatMap { try store.messages(chatID: $0, limit: .max) }.sorted { $0.date < $1.date }
                }
                return (latest, threads)
            }.value
            let health = await Task.detached {
                zip(conversations, loaded).map { PersonHealth.health(for: $0, messages: $1) }
            }.value
            cursor = latest
            for id in Array(loops.keys) + Array(judging.keys) { invalidateLoops(id) }
            threads = Dictionary(uniqueKeysWithValues: zip(conversations.map(\.id), loaded))
            let names = picker.names
            people = zip(conversations, health)
                .map { conversation, health in
                    var person = PersonHealth(conversation: conversation, title: picker.title(for: conversation), health: health)
                    if conversation.isGroup {
                        for handle in conversation.participants { person.memberNames[handle] = names.name(for: handle) }
                    }
                    return person
                }
                .sorted { $0.messageCount > $1.messageCount }
            phase = .health
            startSyncing()
            let chosen = Set(people.map(\.id))
            await Task.detached(priority: .utility) { _ = try? Self.openMemory()?.index.prune(keeping: chosen) }.value
            updateMemory(for: people)
            judgePromises()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func startSyncing() {
        syncing?.cancel()
        guard liveSyncEnabled else { return }
        syncing = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await syncOnce()
            }
        }
    }

    private func syncOnce() async {
        let after = cursor
        guard let fresh = try? await Task.detached(operation: { () throws -> [Message]? in
            let store = try MessagesStore()
            guard try store.latestRowID() > after else { return nil }
            return try store.newMessages(after: after)
        }).value, let newest = fresh.last?.id else { return }
        cursor = newest

        for (id, arrived) in LiveSync.route(fresh, to: people.map(\.conversation)) {
            guard let conversation = people.first(where: { $0.id == id })?.conversation else { continue }
            let existing = threads[id] ?? []
            let known = Set(existing.suffix(500).map(\.id))
            let merged = (existing + arrived.filter { !known.contains($0.id) }).sorted { $0.date < $1.date }
            let health = await Task.detached { PersonHealth.health(for: conversation, messages: merged) }.value
            guard !Task.isCancelled, let index = people.firstIndex(where: { $0.id == id }) else { return }
            threads[id] = merged
            people[index].health = health
            invalidateLoops(id)
            updateMemory(for: [people[index]])
        }
        judgePromises()
    }
}

extension AppModel {
    /// Sample data shaped like the design mock, for SwiftUI previews only.
    static func preview() -> AppModel {
        let model = AppModel()
        let day: TimeInterval = 86_400
        func message(_ id: Int64, _ me: Bool, _ text: String, daysAgo: Double, chat: Int64 = 2) -> Message {
            Message(id: id, guid: "\(id)", chatID: chat, sender: me ? nil : "maya@example.com", isFromMe: me,
                    date: .now.addingTimeInterval(-daysAgo * day), text: text, textSource: .column, kind: .text)
        }
        var history: [Message] = []
        for week in stride(from: 160, to: 8, by: -2) {
            history.append(message(Int64(1000 + week * 2), false, "how was your week", daysAgo: Double(week)))
            history.append(message(Int64(1001 + week * 2), true, "pretty good! busy with the move stuff", daysAgo: Double(week) - 0.01))
        }
        let maya = history + [
            message(1, false, "Interview went… fine? I think? They want a second round", daysAgo: 6),
            message(2, true, "That’s huge. When’s round two", daysAgo: 5.99),
            message(3, false, "Next Thursday. Also still waiting on those Big Sur photos", daysAgo: 5.98),
            message(4, true, "Yes yes. Tonight, promise", daysAgo: 5.97),
            message(5, false, "haha ok but did you ever find those photos", daysAgo: 0.1),
        ]
        let mayaChat = Chat(id: 2, identifier: "maya@example.com", displayName: nil, isGroup: false, participants: ["maya@example.com"],
                            messageCount: maya.count, lastMessageDate: maya.last?.date)
        var people = samplePeople().filter { !$0.conversation.isGroup && $0.id != 2 }
        people.insert(PersonHealth(conversation: Conversation(chats: [mayaChat]), title: "Maya Chen",
                                   health: .person(RelationshipMetrics.compute(maya))), at: 0)
        people.append(sampleGroup())
        model.people = people
        model.threads = [2: maya.sorted { $0.date < $1.date }]
        model.threads[1] = [
            message(2000, true, "landed, love you", daysAgo: 2, chat: 1),
            message(2001, false, "Are you still coming Sunday? Dad wants to grill", daysAgo: 0.15, chat: 1),
        ]
        model.loops[2] = .judged([
            OpenLoop(id: 4, task: "Send the Big Sur photos", date: maya[maya.count - 2].date, isConfirmed: true),
            OpenLoop(id: 2, task: "Ask how round two goes", date: maya[maya.count - 4].date, isConfirmed: true),
        ])
        model.topicsCache[2] = ["job search", "portland move", "climbing", "her sister", "photos"]
        model.remindersCache[2] = [Reminder(when: "Nov 8", text: "Her sister’s wedding in Portland"),
                                   Reminder(when: "Thursday", text: "Her second-round interview")]
        let wedding = Moment(conversationID: 2, firstMessageID: 900, lastMessageID: 901, start: .now.addingTimeInterval(-50 * day),
                             end: .now.addingTimeInterval(-50 * day), text: "Maya Chen: my sister’s wedding is Nov 8 in Portland, can you come?")
        model.recalledCache[2] = MemoryResult(moment: wedding, title: "Maya Chen", score: 0.91)
        model.labels = [2: .friend]
        var picker = ConversationPicker(chats: [
            Chat(id: 1, identifier: "+15550104471", displayName: nil, isGroup: false, participants: ["+15550104471"],
                 messageCount: 11_804, lastMessageDate: .now, firstMessageDate: .now.addingTimeInterval(-3_600 * day), service: "iMessage"),
            mayaChat,
            Chat(id: 3, identifier: "chat42", displayName: "Ybarra family", isGroup: true,
                 participants: ["+15550100001", "+15550100002", "+15550100003", "+15550100004", "+15550100005"],
                 messageCount: 3_977, lastMessageDate: .now, firstMessageDate: .now.addingTimeInterval(-2_100 * day), service: "iMessage"),
            Chat(id: 4, identifier: "+15550109932", displayName: nil, isGroup: false, participants: ["+15550109932"],
                 messageCount: 418, lastMessageDate: .now, firstMessageDate: .now.addingTimeInterval(-1_400 * day), service: "SMS"),
        ], preselect: 3)
        picker.names = HandleDirectory(entries: [.init(name: "Mom", phones: ["5550104471"], emails: []),
                                                 .init(name: "Maya Chen", phones: [], emails: ["maya@example.com"])])
        model.picker = picker
        model.phase = .health
        return model
    }
}
