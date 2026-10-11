import OdeCore
import SwiftUI

/// The design's main window: top bar, sidebar of conversations, a center pane with
/// Health · Thread · Memory tabs, and the Lens beside Thread and Memory.
struct MainView: View {
    enum Tab: String, CaseIterable {
        case health = "Health"
        case thread = "Thread"
        case memory = "Memory"
    }

    @Bindable var model: AppModel
    @State private var selection: Int64?
    @State private var tab = Tab.thread
    @State private var query = ""
    @State private var results: [MemoryResult]?
    @State private var focus: Int64?
    @State private var draftRequest: DraftRequest?
    @State private var pendingEdit: String?
    @State private var showingSettings = false
    @State private var home = true
    @FocusState private var searchFocused: Bool

    struct DraftRequest: Identifiable {
        let person: PersonHealth
        let steer: String
        var spoken = ""
        let id = UUID()
    }

    private var selected: PersonHealth? {
        model.people.first { $0.id == selection } ?? model.people.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                Sidebar(model: model, selection: home ? nil : selected?.id, home: home, showHome: {
                    home = true
                    draftRequest = nil
                    focus = nil
                    results = nil
                }) { id in
                    selection = id
                    home = false
                    draftRequest = nil
                    focus = nil
                    results = nil
                }
                Divider().overlay(Theme.hairline)
                if let request = draftRequest {
                    DraftComposerView(model: model, person: request.person, close: { draftRequest = nil }, steer: request.steer,
                                      spoken: request.spoken, edit: pendingEdit, editHandled: { pendingEdit = nil })
                        .id(request.id)
                } else if let results {
                    MemoryResultsView(query: query, results: results) { open($0) }
                } else if home {
                    WaitingView(model: model, reply: { person, steer in
                        draftRequest = DraftRequest(person: person, steer: steer)
                    }, open: { id in
                        selection = id
                        tab = .thread
                        home = false
                    })
                } else if let person = selected {
                    center(person)
                    if tab != .health {
                        Divider().overlay(Theme.hairline)
                        LensView(model: model, person: person)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model).frame(width: 1100, height: 780)
        }
        .alert(consentTitle, isPresented: Binding(get: { model.ai.pendingConsent != nil }, set: { _ in })) {
            Button("Keep on this Mac", role: .cancel) { model.ai.pendingConsent?.resolve(false) }
            Button("Allow") { model.ai.pendingConsent?.resolve(true) }
        } message: {
            Text(consentMessage)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Wordmark().frame(width: 244, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(model.memoryEnabled ? "Ask anything across every conversation" : "Memory is off", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .disabled(!model.memoryEnabled)
                    .onSubmit(runSearch)
                    .onChange(of: query) { if query.isEmpty { results = nil } }
                Text("⌘K").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: 560)
            .background(Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            Button("") { searchFocused = true }.keyboardShortcut("k").hidden().frame(width: 0)
            Spacer()
            if let progress = model.indexingProgress {
                ProgressView(value: progress).frame(width: 60).help("Building memory on this Mac")
            }
            Button(action: model.changeConversations) {
                Label("Add threads", systemImage: "plus").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(CompactPrimaryButtonStyle())
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private func center(_ person: PersonHealth) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(person.title).font(.system(size: 22, weight: .semibold)).tracking(-0.4).lineLimit(1)
                    Text(subtitle(person)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(model.memoryEnabled ? "\(person.messageCount.formatted()) messages indexed" : "\(person.messageCount.formatted()) messages")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 24) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: tab == item ? .medium : .regular))
                                .foregroundStyle(tab == item ? Theme.ink : Theme.muted)
                                .padding(.bottom, 12)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(tab == item ? Theme.ink : .clear).frame(height: 2)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .background(Theme.surface)
            Divider().overlay(Theme.hairline)
            switch (tab, person.health) {
            case (.thread, _):
                ThreadView(model: model, person: person, focus: focus) { steer in
                    draftRequest = DraftRequest(person: person, steer: steer)
                }
            case (.memory, _):
                PersonMemoryView(model: model, person: person) { open($0) }
            case (.health, .person):
                PersonHealthView(model: model, person: person) { messageID in
                    focus = messageID
                    tab = .thread
                }
            case (.health, .group(let metrics)):
                GroupHealthDetail(group: person, metrics: metrics, loadOpenLoops: model.openLoops(for:))
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }

    private var consentTitle: String {
        guard let request = model.ai.pendingConsent else { return "" }
        return "Send messages with \(request.conversation) to \(request.provider.name)?"
    }

    private var consentMessage: String {
        guard let request = model.ai.pendingConsent else { return "" }
        let redaction = model.ai.redactBeforeCloud ? " Phone numbers, emails and addresses are replaced first." : ""
        return "A job you routed to \(request.provider.name) needs recent messages from this conversation. They leave this Mac for that request.\(redaction) Ode asks once per conversation; change this in Settings."
    }

    private func subtitle(_ person: PersonHealth) -> String {
        let kind = person.conversation.isGroup ? "Group · \(person.conversation.participants.count + 1) people" : (model.labels[person.id]?.rawValue ?? "Contact")
        guard let since = model.since(person) else { return kind }
        return "\(kind) · since \(since.formatted(.dateTime.year()))"
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = nil; return }
        draftRequest = nil
        Task { results = await model.searchMemory(text) }
    }

    private func open(_ result: MemoryResult) {
        home = false
        selection = result.moment.conversationID
        focus = result.moment.firstMessageID
        tab = .thread
        results = nil
    }
}

private struct Sidebar: View {
    @Bindable var model: AppModel
    let selection: Int64?
    let home: Bool
    let showHome: () -> Void
    let select: (Int64) -> Void
    @State private var confirmingMemoryDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    homeEntry
                    let individuals = model.people.filter { !$0.conversation.isGroup }
                    section("Pinned", model.people.filter { model.pinned.contains($0.id) })
                    ForEach(Relationship.allCases) { label in
                        section(label.rawValue == "Friend" ? "Friends" : label.rawValue,
                                individuals.filter { model.labels[$0.id] == label && !model.pinned.contains($0.id) })
                    }
                    section("People", individuals.filter { model.labels[$0.id] == nil && !model.pinned.contains($0.id) })
                    section("Groups", model.people.filter { $0.conversation.isGroup && !model.pinned.contains($0.id) })
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            Divider().overlay(Theme.hairline)
            Toggle(isOn: Binding(get: { model.memoryEnabled }, set: { on in
                if on { model.memoryEnabled = true } else { confirmingMemoryDelete = true }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory").font(.system(size: 13, weight: .medium))
                    Text("Searchable copy kept on this Mac").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(16)
            .confirmationDialog("Delete memory?", isPresented: $confirmingMemoryDelete) {
                Button("Delete memory", role: .destructive) { model.memoryEnabled = false }
            } message: {
                Text("This erases the searchable copy of your conversations from this Mac. Health, threads and open loops keep working.")
            }
        }
        .frame(width: 280)
    }

    private var homeEntry: some View {
        let count = model.waiting.count
        return Button(action: showHome) {
            HStack(spacing: 10) {
                Image(systemName: "tray").font(.system(size: 14)).frame(width: 32, height: 32)
                Text("Waiting on you").font(.system(size: 14, weight: .medium))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(11))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Theme.accent, in: .capsule)
                }
            }
            .padding(8)
            .background(home ? Theme.surface : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(home ? Theme.hairline : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Waiting on you, \(count)")
    }

    @ViewBuilder private func section(_ title: String, _ rows: [PersonHealth]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                ForEach(rows) { row($0) }
            }
        }
    }

    private func row(_ person: PersonHealth) -> some View {
        let last = model.lastMessage(person)
        let isSelected = person.id == selection
        return Button { select(person.id) } label: {
            HStack(spacing: 10) {
                Avatar(title: person.title, photo: person.photo, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(person.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(last.map { Self.time($0.date) } ?? "").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 6) {
                        Text(snippet(last, person)).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if person.needsAttention {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7).accessibilityLabel("Something changed")
                        }
                    }
                }
            }
            .padding(8)
            .background(isSelected ? Theme.surface : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.hairline : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(model.pinned.contains(person.id) ? "Unpin" : "Pin") { model.togglePin(person.id) }
            if !person.conversation.isGroup {
                Picker("Relationship", selection: Binding(get: { model.labels[person.id] }, set: { model.setLabel($0, for: person.id) })) {
                    Text("None").tag(Relationship?.none)
                    ForEach(Relationship.allCases) { Text($0.rawValue).tag(Relationship?.some($0)) }
                }
            }
        }
    }

    private func snippet(_ message: Message?, _ person: PersonHealth) -> String {
        guard let message else { return "" }
        let text = message.text ?? "Attachment"
        guard person.conversation.isGroup, !message.isFromMe else { return text }
        let name = person.memberName(message.sender).split(separator: " ").first.map(String.init) ?? ""
        return "\(name): \(text)"
    }

    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

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

struct CompactPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: 8))
    }
}

#Preview {
    MainView(model: .preview())
        .frame(width: 1440, height: 960)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
}
