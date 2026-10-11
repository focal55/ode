import Contacts
import FoundationModels
import OdeCore
import SwiftUI

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case models = "AI models"
        case access = "Messages access"
        case privacy = "Privacy & data"
        case about = "About"
        var id: Self { self }
    }

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.models

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Section.allCases) { item in
                        Button { section = item } label: {
                            Text(item.rawValue)
                                .font(.system(size: 14, weight: section == item ? .medium : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(section == item ? Theme.surface : .clear, in: .rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(section == item ? Theme.hairline : .clear))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 220)
                Divider().overlay(Theme.hairline)
                ScrollView {
                    Group {
                        switch section {
                        case .models: ModelsSettings(ai: model.ai, labels: model.labels)
                        case .access: AccessSettings(model: model)
                        case .privacy: PrivacySettings(model: model)
                        case .about: AboutSettings()
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 860, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
            }
        }
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
    }
}

// MARK: - AI models

private struct ModelsSettings: View {
    @Bindable var ai: AISettings
    let labels: [Int64: Relationship]
    @State private var keyDrafts: [Provider: String] = [:]
    @State private var capText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI models").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                Text(AISettings.cloudEnabled
                     ? "Apple Intelligence handles everything by default. Add your own keys only if you want a different model for a job — they live in your Mac’s Keychain."
                     : "Apple Intelligence handles everything by default. Point a job at a local model if you want something stronger — nothing leaves your Mac either way.")
                    .foregroundStyle(Theme.secondary)
            }

            group("Default · Apple Intelligence") {
                providerRow("On-device model", detail: "Built in · no key · nothing leaves your Mac") {
                    status(SystemLanguageModel.default.isAvailable ? "Available" : "Turn on Apple Intelligence", ok: SystemLanguageModel.default.isAvailable)
                }
                Divider().overlay(Theme.hairline)
                providerRow("Private Cloud Compute", detail: "Apple’s servers for longer histories · needs an Apple entitlement Ode doesn’t have yet") {
                    Text("Not available").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .opacity(0.6)
            }

            group(AISettings.cloudEnabled ? "Optional · your own keys and local models" : "Optional · local models") {
                if AISettings.cloudEnabled {
                    keyRow(.anthropic, detail: "Claude models · used for jobs you route to them")
                    Divider().overlay(Theme.hairline)
                    keyRow(.openAI, detail: "Optional · alternate drafting model")
                    Divider().overlay(Theme.hairline)
                }
                localRow
            }

            group("Which model does what", trailing: "Cheaper models for frequent jobs, stronger ones where judgment matters") {
                ForEach(AIJob.allCases) { job in
                    routeRow(job)
                    Divider().overlay(Theme.hairline)
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Memory (embeddings)").font(.system(size: 14, weight: .medium))
                        Text("Indexes every message for recall. Always local — your archive never leaves the Mac.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text("MiniLM on device (locked)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    where_("ON MAC", local: true)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }

            if AISettings.cloudEnabled { cloudRules }
        }
        .task {
            if AISettings.cloudEnabled {
                for provider in [Provider.anthropic, .openAI] where ai.hasKey(provider) { await ai.verify(provider) }
            }
            await ai.verify(.local)
        }
    }

    private var cloudRules: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                label("What goes to the cloud")
                checkbox($ai.askBeforeCloud, "Ask before a conversation is sent to a cloud model for the first time",
                         "Shows which provider and which conversation")
                checkbox($ai.redactBeforeCloud, "Strip phone numbers, emails and addresses before sending",
                         "Replaced with placeholders, restored in what comes back")
                checkbox($ai.familyOnDevice, "On-device only for Family",
                         familyNames.isEmpty ? "Label people as Family from the sidebar" : "\(familyNames) never reach a cloud model")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            spendCard.frame(width: 300)
        }
    }

    private var familyNames: String {
        let count = labels.values.filter { $0 == .family }.count
        return count == 0 ? "" : "\(count) \(count == 1 ? "person" : "people") labeled Family"
    }

    private func keyRow(_ provider: Provider, detail: String) -> some View {
        providerRow(provider.name, detail: detail) {
            if let masked = ai.maskedKey(provider) {
                Text(masked).font(Theme.mono(12)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(red: 0.949, green: 0.949, blue: 0.937), in: .rect(cornerRadius: 6))
                verification(provider)
                Button("Remove") { ai.removeKey(provider) }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
            } else {
                SecureField("Paste API key", text: Binding(get: { keyDrafts[provider] ?? "" }, set: { keyDrafts[provider] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .frame(width: 240)
                Button("Save & test") {
                    let key = keyDrafts[provider] ?? ""
                    keyDrafts[provider] = nil
                    Task { await ai.saveKey(key, for: provider) }
                }
                .buttonStyle(CompactPrimaryButtonStyle())
                .disabled((keyDrafts[provider] ?? "").isEmpty)
                verification(provider)
            }
        }
    }

    private var localRow: some View {
        providerRow("Local (LM Studio)", detail: "OpenAI-compatible server on this Mac · nothing leaves it") {
            TextField("http://localhost:1234/v1", text: $ai.localBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                .frame(width: 210)
            verification(.local)
            Button("Test") { Task { await ai.verify(.local) } }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func verification(_ provider: Provider) -> some View {
        switch ai.verified[provider] {
        case true?:
            status(provider == .local ? "\(ai.models[.local]?.count ?? 0) models" : "Verified", ok: true)
        case false?:
            Text(ai.verificationError[provider] ?? "Failed").font(.system(size: 12)).foregroundStyle(Theme.warning).lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func routeRow(_ job: AIJob) -> some View {
        let current = ai.routes[job] ?? .onDevice
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.system(size: 14, weight: .medium))
                Text(job.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Picker(job.title, selection: Binding(get: { current }, set: { ai.routes[job] = $0 })) {
                Text("Apple on-device").tag(Route.onDevice)
                ForEach(AISettings.cloudEnabled ? [Provider.anthropic, .openAI, .local] : [.local]) { provider in
                    if provider == .local ? ai.verified[.local] == true : ai.hasKey(provider) {
                        Section(provider.name) {
                            ForEach(ai.models[provider] ?? [], id: \.self) { id in
                                Text(id).tag(Route(provider: provider, model: id))
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 260)
            where_(current.provider.leavesTheMac ? "CLOUD" : "ON MAC", local: !current.provider.leavesTheMac)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var spendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("Spend this month")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ai.monthSpend.formatted(.currency(code: "USD"))).font(Theme.mono(26).weight(.medium))
                Text("of \(ai.monthlyCap.formatted(.currency(code: "USD"))) cap").foregroundStyle(Theme.muted)
            }
            ProgressView(value: min(ai.monthSpend / max(ai.monthlyCap, 0.01), 1)).tint(Theme.accent)
            HStack {
                Text("Monthly cap").font(.system(size: 13))
                Spacer()
                TextField("20", value: $ai.monthlyCap, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            Text("Anthropic spend, estimated from token usage at published rates. At the cap, jobs fall back to on-device.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if ai.monthTokens(.openAI) > 0 {
                Text("OpenAI: \(ai.monthTokens(.openAI).formatted()) tokens this month").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if ai.monthTokens(.local) > 0 {
                Text("Local: \(ai.monthTokens(.local).formatted()) tokens, free").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(18)
        .background(Theme.ground, in: .rect(cornerRadius: 14))
    }

    private func group(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                label(title)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            VStack(spacing: 0) { content() }
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
        }
    }

    private func providerRow(_ name: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private func status(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.positive : Theme.warning).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(ok ? Theme.positive : Theme.warning)
        }
    }

    private func where_(_ text: String, local: Bool) -> some View {
        Text(text).font(Theme.mono(11)).foregroundStyle(local ? Theme.positive : Theme.warning).frame(width: 64, alignment: .trailing)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.9).foregroundStyle(Theme.muted)
    }

    private func checkbox(_ binding: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Other sections

private struct AccessSettings: View {
    @Bindable var model: AppModel
    @State private var messages: MessagesAccess?
    @AppStorage(OdeVoice.settingKey) private var odeSpeaks = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Messages access").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            row("Full Disk Access", messages == .granted ? "Granted · Ode reads Messages read-only" : "Not granted",
                ok: messages == .granted) {
                Button("Open System Settings") { openURL(MessagesAccess.settingsURL) }.buttonStyle(.bordered)
            }
            row("Contacts", contactsStatus, ok: CNContactStore.authorizationStatus(for: .contacts) == .authorized) { EmptyView() }
            Toggle("Keep syncing new messages", isOn: $model.liveSyncEnabled).toggleStyle(.checkbox)
            Text("When on, Ode checks for new messages every five seconds while it’s open.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Toggle("Ode says its short lines out loud", isOn: $odeSpeaks).toggleStyle(.checkbox)
            Text("Things like \u{201C}Maya asked you something on Tuesday.\u{201D} Ode never reads anyone\u{2019}s messages aloud.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .task { messages = await Task.detached { MessagesAccess.check() }.value }
    }

    private var contactsStatus: String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: "Granted · names instead of numbers"
        case .denied, .restricted: "Denied · change in System Settings › Privacy & Security › Contacts"
        default: "Not asked yet"
        }
    }

    private func row(_ title: String, _ detail: String, ok: Bool, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Circle().fill(ok ? Theme.positive : Theme.warning).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            action()
        }
    }
}

private struct PrivacySettings: View {
    @Bindable var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Privacy & data").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { model.memoryEnabled }, set: { on in
                    if on { model.memoryEnabled = true } else { confirmingDelete = true }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Memory")
                        Text("A searchable copy of chosen conversations, kept in ~/Library/Application Support/Ode. Turning it off deletes it.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch)
            }
            if AISettings.cloudEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Forget cloud permissions") { model.ai.forgetConsents() }.buttonStyle(.bordered)
                    Text("Ode will ask again before sending any conversation to a cloud model.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Text("Ode never sends messages for you, and API keys stay in your Keychain.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .confirmationDialog("Delete memory?", isPresented: $confirmingDelete) {
            Button("Delete memory", role: .destructive) { model.memoryEnabled = false }
        } message: {
            Text("This erases the searchable copy of your conversations from this Mac.")
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text("Ode \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            Text("Memory search uses all-MiniLM-L6-v2 by the sentence-transformers authors, under the Apache License 2.0. The full notice ships with the app.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if let url = Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: "txt") {
                Button("Show license") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    SettingsView(model: .preview()).frame(width: 1100, height: 900)
}
