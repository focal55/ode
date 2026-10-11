import AVFoundation
import Observation
import Speech

/// Push-to-talk transcription, entirely on this Mac. `press` when Space goes down, `release` then `finish` when it
/// comes up. Both state changes happen synchronously on the main actor, so a release can never be missed by setup.
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

    func press() {
        guard [.idle, .denied, .unavailable].contains(state) else { return }
        state = .preparing
        transcript = ""
        finalized = ""
        released = false
        Task { await prepare() }
    }

    func release() {
        released = true
    }

    /// The final transcript, or "" if nothing was heard or the mic never started.
    func finish() async -> String {
        guard state == .listening else { return "" }
        state = .finishing
        try? await Task.sleep(for: .milliseconds(300))
        await stopSession()
        feeding?.cancel()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reading?.value
        (analyzer, input, feeding, reading) = (nil, nil, nil, nil)
        state = .idle
        return transcript
    }

    private func prepare() async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { state = .denied; return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              let device = AVCaptureDevice.default(for: .audio) else { state = .unavailable; return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            // Let go during the permission prompt or the download: never open the mic at all.
            guard !released else { state = .idle; return }
            let provider = try await CaptureInputSequenceProvider.providerWithSession(from: device, compatibleWith: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            guard !released else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                state = .idle
                return
            }
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
            let inputs = provider.analyzerInputs
            feeding = Task.detached {
                do { for try await item in inputs { continuation.yield(item) } } catch {}
            }
            (self.analyzer, session, input) = (analyzer, provider.captureSession, continuation)
            await startSession()
            state = .listening
            if released { _ = await finish() }
        } catch {
            state = .unavailable
        }
    }

    /// `startRunning` and `stopRunning` block, so they run off the main actor.
    private func startSession() async {
        nonisolated(unsafe) let session = session
        await Task.detached { session?.startRunning() }.value
    }

    private func stopSession() async {
        nonisolated(unsafe) let session = session
        self.session = nil
        await Task.detached { session?.stopRunning() }.value
    }
}
