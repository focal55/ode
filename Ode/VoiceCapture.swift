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
        // Preparing from the first await, so letting go of Space during the permission prompt can't leave the mic on.
        state = .preparing
        guard await AVCaptureDevice.requestAccess(for: .audio) else { state = .denied; return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              let device = AVCaptureDevice.default(for: .audio) else { state = .unavailable; return }
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
