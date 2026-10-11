import AppKit
import OdeCore
import SwiftUI

/// The design's draft composer: what you're replying to and the context used, three drafts
/// with how much they sound like you, and checks before you send.
struct DraftComposerView: View {
    let model: AppModel
    let person: PersonHealth
    let close: () -> Void

    @State var steer: String
    var initialResult: DraftResult?
    var spoken = ""
    var edit: String?
    var editHandled: () -> Void = {}
    @State private var length = DraftLength.balanced
    /// Every set drafted so far, so a redraft never costs you one you liked.
    @State private var sets: [DraftSet] = []
    @State private var index = 0
    @State private var notice: DraftResult?
    @State private var work: Work?
    @State private var startedAt: Date?
    @State private var task: Task<Void, Never>?
    @State private var chosen: String?
    @State private var edits: [String: String] = [:]
    @State private var editing: String?
    @State private var recalled: MemoryResult?
    @State private var copied = false
    /// A spoken edit that arrived while a draft was still being written.
    @State private var queuedEdit: String?

    struct DraftSet {
        let drafts: [Draft]
        let onDevice: Bool
        var ahead = false
    }

    enum Work: Equatable {
        case all
        case card(String)
    }

    private var messages: [Message] { model.threads[person.id] ?? [] }
    private var style: WritingStyle { WritingStyle(of: messages) }
    private var current: DraftSet? { sets.indices.contains(index) ? sets[index] : nil }
    private var drafts: [Draft] { current?.drafts ?? [] }
    private var inYourWords: Bool { drafts.first?.label == VoiceDrafter.label }
    private var route: Route { model.draftingRoute(for: person) }

    private var modelName: String {
        route.provider == .onDevice ? "Apple on-device" : String(route.model.split(separator: "/").last ?? "")
    }

    private func editKey(_ draft: Draft) -> String { "\(index)|\(draft.id)" }

    private func text(of draft: Draft) -> String { edits[editKey(draft)] ?? draft.text }

    private var selectedText: String? {
        guard let id = chosen ?? drafts.first?.id, let draft = drafts.first(where: { $0.id == id }) else { return nil }
        return text(of: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                context.frame(width: 330)
                Divider().overlay(Theme.hairline)
                composer.frame(maxWidth: .infinity)
                Divider().overlay(Theme.hairline)
                sendPanel.frame(width: 300)
            }
        }
        .background(Theme.ground)
        .task {
            recalled = await model.recalled(for: person)
            if !spoken.isEmpty {
                start(.all) { await model.voiceDraft(for: person, request: spoken) }
            } else if let initialResult {
                accept(initialResult)
            } else if let ready = model.readyDrafts(for: person, steer: steer) {
                accept(ready, ahead: true)
            } else {
                generate()
            }
        }
        .onDisappear { task?.cancel() }
        .onChange(of: edit) { _, instruction in
            guard let instruction else { return }
            editHandled()
            revise(instruction)
        }
        .onChange(of: work) { _, work in
            guard work == nil, let instruction = queuedEdit else { return }
            queuedEdit = nil
            revise(instruction)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: close) {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to thread")
            VStack(alignment: .leading, spacing: 0) {
                Text("Reply to \(person.title)").font(.system(size: 14, weight: .semibold))
                Text("Ode never sends · you send from Messages").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var context: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                label("Replying to")
                ForEach(messages.filter { $0.kind == .text }.suffix(3)) { message in
                    Text(message.text ?? "")
                        .font(.system(size: 14))
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .foregroundStyle(message.isFromMe ? .white : Theme.ink)
                        .background(message.isFromMe ? Theme.ink : Theme.surface, in: .rect(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(message.isFromMe ? .clear : Theme.hairline))
                        .frame(maxWidth: 260, alignment: message.isFromMe ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
                }
                label("Context used").padding(.top, 18)
                ForEach(model.confirmedLoops(for: person)) { loop in
                    contextCard(loop.task, "OPEN LOOP · \(Elapsed.ago(loop.date).uppercased())")
                }
                if let recalled {
                    contextCard(recalled.moment.text, "MEMORY · \(recalled.moment.start.formatted(.dateTime.month(.abbreviated).day()).uppercased())")
                }
                if let summary = style.summary {
                    contextCard(summary, "YOUR STYLE WITH \(person.title.uppercased())")
                }
            }
            .padding(22)
        }
    }

    private var composer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(inYourWords ? "In your words" : "Three ways to say it").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                        if sets.count > 1 { pager }
                        Spacer()
                        lengthPicker
                    }
                    status
                }

                if !drafts.isEmpty {
                    ForEach(drafts) { draft in
                        card(draft)
                            .id(editKey(draft))
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                } else if work != nil {
                    ForEach(["DIRECT", "WARM", "PLAYFUL"], id: \.self, content: skeleton)
                } else {
                    switch notice {
                    case .unavailable?:
                        Text("Drafting needs Apple Intelligence, which is off on this Mac.").foregroundStyle(Theme.secondary)
                    case .blocked?:
                        Text("Apple’s on-device model declined to draft for this conversation. Try steering it differently.").foregroundStyle(Theme.secondary)
                    default:
                        Text("Stopped. Redraft when you’re ready.").foregroundStyle(Theme.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Steer it").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        TextField("e.g. apologize for the delay, mention the wedding", text: $steer)
                            .textFieldStyle(.plain)
                            .onSubmit { generate() }
                        if work == nil {
                            Button { generate() } label: { Label("Redraft all", systemImage: "arrow.clockwise") }
                                .buttonStyle(AccentButtonStyle())
                                .keyboardShortcut("r", modifiers: .command)
                                .help("Three new drafts (⌘R). Earlier sets stay one click away.")
                        } else {
                            Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 8)
                    .frame(minHeight: 48)
                    .background(Color(red: 0.984, green: 0.984, blue: 0.980), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .animation(.easeOut(duration: 0.25), value: index)
            .animation(.easeOut(duration: 0.2), value: work)
        }
        .background(Theme.surface)
    }

    private var lengthPicker: some View {
        HStack(spacing: 0) {
            ForEach(DraftLength.allCases, id: \.self) { option in
                Button { length = option; generate() } label: {
                    Text(option.rawValue)
                        .fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(length == option ? Theme.ink : Theme.secondary)
                        .background(length == option ? Theme.surface : .clear, in: .rect(cornerRadius: 7))
                        .shadow(color: length == option ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(red: 0.949, green: 0.949, blue: 0.937), in: .rect(cornerRadius: 9))
        .disabled(work != nil)
        .opacity(work != nil ? 0.5 : 1)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button { show(index - 1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                .disabled(index == 0)
                .accessibilityLabel("Earlier drafts")
            Text("\(index + 1) of \(sets.count)").font(Theme.mono(11)).foregroundStyle(Theme.muted).monospacedDigit()
            Button { show(index + 1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                .disabled(index == sets.count - 1)
                .accessibilityLabel("Later drafts")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .disabled(work != nil)
    }

    /// One line that always says who is writing, for how long, and when the chosen model didn't answer.
    @ViewBuilder private var status: some View {
        let place = route.provider.leavesTheMac ? "via \(route.provider.name)" : "on this Mac"
        if let work, let started = startedAt {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(work == .all ? "Writing \(drafts.isEmpty ? "" : "new ")drafts with \(modelName) \(place)"
                                  : "Writing another \(workLabel) with \(modelName)")
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(started))))s").monospacedDigit().foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
        } else if let current, current.onDevice, route.provider != .onDevice {
            Label("Apple’s on-device model wrote these. \(model.ai.localProblem ?? "\(modelName) didn’t answer.")",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 13)).foregroundStyle(Theme.warning)
        } else if notice == .blocked, !sets.isEmpty {
            Text("That redraft was declined. These are your last drafts.").font(.system(size: 13)).foregroundStyle(Theme.warning)
        } else if let current {
            Text("By \(current.onDevice ? "Apple on-device" : modelName) · \(current.onDevice ? "on this Mac" : place)\(current.ahead ? " · written before you opened this" : "")")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
    }

    private var workLabel: String {
        if case .card(let label) = work { return label.lowercased() }
        return ""
    }

    private func card(_ draft: Draft) -> some View {
        let text = text(of: draft)
        let isChosen = (chosen ?? drafts.first?.id) == draft.id
        let isRewriting = work == .all || work == .card(draft.id)
        let percent = style.sampleSize >= 5 ? "SOUNDS LIKE YOU \(Int((style.match(text) * 100).rounded()))%" : ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.label).font(Theme.mono(11)).tracking(0.6).foregroundStyle(Theme.muted)
                Spacer()
                Text(percent).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            if editing == draft.id {
                TextEditor(text: Binding(get: { text }, set: { edits[editKey(draft)] = $0 }))
                    .font(.system(size: 16))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
            } else {
                Text(text).font(.system(size: 16)).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(draft.why).font(.system(size: 12)).foregroundStyle(Theme.accent)
                Spacer()
                if work == .card(draft.id) {
                    ProgressView().controlSize(.small)
                    Text("Writing another…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    Button { reroll(draft) } label: { Label("Try another", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .help("Rewrite only this one. The others stay.")
                    Button(editing == draft.id ? "Done" : "Edit") { editing = editing == draft.id ? nil : draft.id }
                        .buttonStyle(.bordered)
                    Button("Use") { chosen = draft.id }
                        .buttonStyle(CompactPrimaryButtonStyle())
                }
            }
            .disabled(work != nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(isChosen ? Theme.surface : Color(red: 0.984, green: 0.984, blue: 0.980), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isChosen ? Theme.accent : Theme.hairline, lineWidth: isChosen ? 1.5 : 1))
        .modifier(Pulse(active: isRewriting))
        .contentShape(.rect)
        .onTapGesture { if work == nil { chosen = draft.id } }
    }

    private func skeleton(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(Theme.mono(11)).tracking(0.6).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.hairline).frame(height: 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.hairline).frame(width: 220, height: 12)
            }
            RoundedRectangle(cornerRadius: 4).fill(Theme.accentWash).frame(width: 140, height: 10)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.984, green: 0.984, blue: 0.980), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
        .modifier(Pulse(active: true))
        .accessibilityLabel("Drafting")
    }

    private var sendPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Before you send")
            if let text = selectedText {
                let lastIncoming = messages.last(where: { !$0.isFromMe && $0.kind == .text })?.text
                ForEach(DraftChecks.evaluate(text, style: style, openLoops: model.confirmedLoops(for: person).map(\.task),
                                             lastIncoming: lastIncoming), id: \.self) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.ok ? "checkmark" : "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(check.ok ? Theme.positive : Theme.warning)
                            .frame(width: 16)
                            .padding(.top, 2)
                        Text(check.text).font(.system(size: 13))
                    }
                }
            } else {
                Text("Pick a draft to see checks.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button { sendViaMessages() } label: {
                Text(copied ? "Copied — paste in Messages" : "Send via Messages").frame(maxWidth: .infinity)
            }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedText == nil)
                .help("Copies the draft and opens the conversation in Messages. You press send.")
            Button("Copy to clipboard") { if let text = selectedText { copy(text) } }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .disabled(selectedText == nil)
        }
        .padding(22)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.9).foregroundStyle(Theme.muted)
    }

    private func contextCard(_ text: String, _ meta: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 13)).lineLimit(4)
            Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.925, green: 0.925, blue: 0.910)))
    }

    private func generate() {
        guard work == nil else { return }
        let avoid = drafts.map(text(of:))
        let steerText = steer.trimmingCharacters(in: .whitespaces).isEmpty ? spoken : steer.trimmingCharacters(in: .whitespaces)
        start(.all) {
            await model.draftReply(for: person, steer: steerText, length: length, avoid: avoid)
        }
    }

    private func revise(_ instruction: String) {
        guard work == nil else {
            queuedEdit = instruction
            return
        }
        guard let base = selectedText else { return }
        start(.all) { await model.voiceRevision(for: person, draft: base, instruction: instruction) }
    }

    private func reroll(_ draft: Draft) {
        guard work == nil, let base = current else { return }
        let previous = text(of: draft)
        start(.card(draft.id)) {
            let result = await model.draftReply(for: person, steer: steer.trimmingCharacters(in: .whitespaces),
                                                length: length, avoid: [previous])
            guard case .drafts(let fresh, let onDevice)? = result,
                  let replacement = fresh.first(where: { $0.id == draft.id }) else { return result }
            return .drafts(base.drafts.map { $0.id == draft.id ? replacement : $0 }, onDevice: onDevice && base.onDevice)
        }
    }

    private func start(_ kind: Work, _ run: @escaping () async -> DraftResult?) {
        work = kind
        startedAt = .now
        notice = nil
        let keepChoice = kind != .all
        task = Task {
            let result = await run()
            guard !Task.isCancelled else { return }
            if let result { accept(result, keepChoice: keepChoice) }
            work = nil
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        work = nil
    }

    private func accept(_ result: DraftResult, keepChoice: Bool = false, ahead: Bool = false) {
        guard case .drafts(let drafts, let onDevice) = result else {
            notice = result
            return
        }
        let carried = edits.filter { $0.key.hasPrefix("\(index)|") }
        sets.append(DraftSet(drafts: drafts, onDevice: onDevice, ahead: ahead))
        let previousIndex = index
        index = sets.count - 1
        editing = nil
        if keepChoice {
            // A single-card rewrite keeps your edits to the other two.
            for (key, value) in carried {
                let id = String(key.dropFirst("\(previousIndex)|".count))
                if let old = sets[previousIndex].drafts.first(where: { $0.id == id }),
                   drafts.first(where: { $0.id == id })?.text == old.text {
                    edits["\(index)|\(id)"] = value
                }
            }
        } else {
            chosen = nil
        }
    }

    private func show(_ newIndex: Int) {
        index = newIndex
        editing = nil
        chosen = nil
    }

    private func copy(_ text: String) {
        model.handOff(person, text: text, openMessages: false)
        copied = true
    }

    private func sendViaMessages() {
        guard let text = selectedText else { return }
        model.handOff(person, text: text, openMessages: true)
        copied = true
    }
}

/// Breathes while a draft is being rewritten, so it's clear which cards are about to change.
private struct Pulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .allowsHitTesting(false)
                .phaseAnimator([0.35, 0.65]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            content
        }
    }
}

#Preview {
    let model = AppModel.preview()
    DraftComposerView(model: model, person: model.people[0], close: {}, steer: "", initialResult: .drafts([
        Draft(label: "DIRECT", text: "found them! sending the whole album tonight, sorry it took a week", why: "Closes the photos loop"),
        Draft(label: "WARM", text: "okay I owe you. album tonight, and good luck thursday, tell me everything after", why: "Closes loop and asks about round two"),
        Draft(label: "PLAYFUL", text: "the photos were hiding from you specifically. freeing them tonight", why: "Matches her tone"),
    ], onDevice: false))
    .frame(width: 1160, height: 900)
    .foregroundStyle(Theme.ink)
    .preferredColorScheme(.light)
}
