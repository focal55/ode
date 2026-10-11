import AVFoundation

/// Ode's own short lines, out loud, in the best voice installed on this Mac. Never anyone's messages.
@MainActor
final class OdeVoice {
    static let settingKey = "odeSpeaks"

    private let synthesizer = AVSpeechSynthesizer()
    private static let voice: AVSpeechSynthesisVoice? = {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }()

    func say(_ line: String) {
        stop()
        guard UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true else { return }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.voice
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
