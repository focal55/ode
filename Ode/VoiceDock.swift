import AppKit
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
            if needsTyping {
                TextField("Type it instead: \"tell Maya I'm in\"", text: $typed)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit {
                        submit(typed)
                        letGo()
                    }
                    .onExitCommand { letGo() }
                    .frame(width: 360)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .padding(.bottom, 20)
        .onChange(of: notice) { _, notice in if notice == .whoFor { typing = true } }
    }

    /// Only shown when Ode needs words it couldn't hear, so the dock never sits on top of the thread's own composer.
    private var needsTyping: Bool {
        notice == .whoFor || notice == .micOff || notice == .unavailable
    }

    /// Hands the keyboard back, so the next Space talks to Ode instead of typing here.
    private func letGo() {
        typing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
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
