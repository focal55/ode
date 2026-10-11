import OdeCore
import SwiftUI

/// The home list: who is waiting to hear from you, most urgent first.
struct WaitingView: View {
    let model: AppModel
    let reply: (PersonHealth, String) -> Void
    let open: (Int64) -> Void

    var body: some View {
        let items = model.waiting
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting on you").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    Text("Watching \(model.people.count) conversations").foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 12)
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nobody's waiting on you").font(.system(size: 17, weight: .semibold))
                        Text("When someone needs a reply, or you promised them something, they'll show up here.")
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 24)
                }
                ForEach(items) { item in
                    if let person = model.people.first(where: { $0.id == item.conversationID }) {
                        row(item, person)
                        Divider().overlay(Theme.hairline)
                    }
                }
                if model.checkingPromises {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking promises")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 16)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
    }

    private func row(_ item: Waiting, _ person: PersonHealth) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(title: person.title, photo: person.photo, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(person.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(Self.label(item.kind).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(item.kind == .asked ? Theme.accent : Theme.muted)
                    Spacer()
                    Text(item.since, format: .relative(presentation: .named))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                }
                Text(item.text).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Reply") { reply(person, item.steer) }.buttonStyle(AccentButtonStyle())
                    Button("Open thread") { open(person.id) }
                    Button("Done") { model.dismiss(item) }
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 16)
    }

    static func label(_ kind: Waiting.Kind) -> String {
        switch kind {
        case .asked: "Asked you"
        case .unanswered: "Unanswered"
        case .promised: "You promised"
        case .quiet: "Gone quiet"
        }
    }
}

#Preview {
    WaitingView(model: .preview(), reply: { _, _ in }, open: { _ in })
        .frame(width: 900, height: 640)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.light)
}
