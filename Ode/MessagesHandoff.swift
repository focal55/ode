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
