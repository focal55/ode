import OdeCore
import SwiftUI

/// The design's "Choose conversations": sources, the conversation list, and what happens next.
struct ChooseView: View {
    @Bindable var model: AppModel

    private var picker: ConversationPicker { model.picker }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 20) {
                    sources
                    list
                }
                .frame(maxWidth: .infinity)
                aside.frame(width: 320)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 32)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if model.canReturnToHealth {
                Button(action: model.returnToHealth) {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text("Choose conversations").font(.system(size: 14, weight: .semibold))
            Spacer()
            if !model.canReturnToHealth {
                Text("STEP 2 OF 2").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var sources: some View {
        HStack(spacing: 10) {
            source("Messages on this Mac", "Connected · live sync via Full Disk Access", selected: true)
            source("Import a file", "Exported chats · coming later", selected: false)
            source("Paste a thread", "Copied text · coming later", selected: false)
        }
    }

    private func source(_ title: String, _ detail: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(selected ? Theme.surface : Color(red: 0.984, green: 0.984, blue: 0.980), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 1.5 : 1))
        .opacity(selected ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Filter people and groups", text: $model.picker.filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                Spacer()
                Text("\(picker.selectedConversations.count) SELECTED · \(picker.selectedMessageCount.formatted()) MESSAGES")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider().overlay(Color(red: 0.937, green: 0.937, blue: 0.925))
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(picker.visible) { conversation in
                        ConversationRow(conversation: conversation, title: picker.title(for: conversation),
                                        photo: picker.names.photo(for: conversation),
                                        isSelected: picker.isSelected(conversation)) {
                            model.picker.toggle(conversation.id)
                        }
                        .padding(.horizontal, 18)
                        Divider().overlay(Color(red: 0.949, green: 0.949, blue: 0.937))
                    }
                }
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("What happens next").font(.system(size: 15, weight: .semibold))
                step("01", "Read", "Pulls the full history of each conversation you choose.")
                step("02", "Index", "Splits threads into moments and embeds each one on this Mac.")
                step("03", "Learn your voice", "Studies how you write to each person so drafts sound like you.")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock").font(.system(size: 14))
                Text("Messages and their embeddings stay on this Mac. Only the conversations you approve are sent to a cloud model, and only if you turn one on in Settings.")
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(Color(red: 0.949, green: 0.949, blue: 0.937), in: .rect(cornerRadius: 14))

            Toggle("Keep syncing new messages", isOn: $model.liveSyncEnabled)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))

            Button { model.importSelected() } label: {
                Text("Import \(picker.selectedConversations.count) conversations").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(picker.selected.isEmpty)
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(Theme.mono(11)).foregroundStyle(Theme.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let title: String
    let photo: Data?
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Toggle(title, isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Avatar(title: title, photo: photo, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(kind).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text(conversation.messageCount.formatted())
                .font(Theme.mono(12))
                .foregroundStyle(Theme.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(conversation.firstMessageDate.map { "SINCE \($0.formatted(.dateTime.year()))" } ?? "")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.muted)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    private var kind: String {
        if conversation.isGroup { return "Group · \(conversation.participants.count + 1) people" }
        let handles = conversation.participants.isEmpty ? [conversation.identifier] : conversation.participants
        let service = conversation.service ?? "Conversation"
        if title == handles.first { return "\(service) · not in Contacts" }
        return handles.count == 1 ? "\(service) · \(handles[0])" : "\(service) · \(handles.count) numbers and emails"
    }
}

#Preview {
    ChooseView(model: .preview())
        .frame(width: 1440, height: 900)
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
}
