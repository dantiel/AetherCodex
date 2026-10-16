import AVFoundation
import Pythia

/// The ætheric voice — Pythia heard *twice at once*.
///
/// The oracle is rendered offline to a temporary audio file, then played through
/// an `AVAudioEngine` graph that splits her into two simultaneous selves:
///
///   • **Presence** — the dry voice, close and centered, *beside* the listener.
///   • **Æther** — a copy detuned a whisper lower, folded through a cathedral
///     reverb, and returned with a faint network-latency echo — *arriving from
///     the internet*.
///
/// The two are mixed, so the priestess speaks at the threshold between the room
/// and the vast. This is the voice that outlives Siri's single canned register:
/// it is not a sound effect laid over speech — it is speech *inhabiting* two
/// places at once.
@MainActor
final class AethericVoiceRenderer: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private enum Tuning {
        static let detuneCents: Float = -22          // the æther copy sings a shade lower
        static let reverbPreset: AVAudioUnitReverbPreset = .cathedral
        static let echoTime: TimeInterval = 0.13     // the latency of the vast
        static let echoFeedback: Float = 16
        static let echoCutoff: Float = 2400
        static let aetherLevel: Float = 0.62         // how much of the æther bleeds through
    }

    private let writeSynthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private let delay = AVAudioUnitDelay()
    private let aetherBus = AVAudioMixerNode()

    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var playbackURL: URL?
    private var completion: (@MainActor () -> Void)?

    override init() {
        super.init()
        writeSynthesizer.delegate = self
        configureEngine()
    }

    // MARK: - Speak

    func speak(_ text: String,
               voice: AVSpeechSynthesisVoice?,
               persona: VoicePersona,
               completion: @escaping @MainActor () -> Void) {
        stop()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.pitchMultiplier = persona.pitch
        utterance.rate = persona.rate
        utterance.volume = persona.volume

        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pythia-aether-\(UUID().uuidString).caf")
        outputFile = nil
        self.completion = completion

        writeSynthesizer.write(utterance) { [weak self] buffer in
            Task { @MainActor in self?.accumulate(buffer) }
        }
    }

    func stop() {
        writeSynthesizer.stopSpeaking(at: .immediate)
        player.stop()
        engine.stop()
        finish()
    }

    // MARK: - Synthesis

    private func accumulate(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        do {
            if outputFile == nil, let url = outputURL {
                outputFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try outputFile?.write(from: pcm)
        } catch {
            // Synthesis continues; playback is simply skipped if the file fails.
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.playbackReady() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish() }
    }

    // MARK: - Playback

    private func playbackReady() {
        guard let url = outputURL else { finish(); return }
        outputFile = nil        // finalize the written file
        outputURL = nil
        playbackURL = url

        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat

            configureAudioSession()
            engine.stop()       // the graph may only be rewired while stopped
            connectGraph(format: format)
            try engine.start()

            player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in self?.playbackFinished() }
            }
            player.play()
        } catch {
            finish()
        }
    }

    private func playbackFinished() {
        player.stop()
        engine.stop()
        finish()
    }

    private func finish() {
        let done = completion
        completion = nil
        outputFile = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
            self.outputURL = nil
        }
        if let playbackURL {
            try? FileManager.default.removeItem(at: playbackURL)
            self.playbackURL = nil
        }
        Task { @MainActor in done?() }
    }

    // MARK: - Engine graph

    private func configureEngine() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(reverb)
        engine.attach(delay)
        engine.attach(aetherBus)

        timePitch.rate = 1.0
        timePitch.pitch = Tuning.detuneCents
        timePitch.overlap = 8.0

        reverb.loadFactoryPreset(Tuning.reverbPreset)
        reverb.wetDryMix = 100        // fully wet: only the tail enters the æther

        delay.delayTime = Tuning.echoTime
        delay.feedback = Tuning.echoFeedback
        delay.lowPassCutoff = Tuning.echoCutoff
        delay.wetDryMix = 40

        aetherBus.outputVolume = Tuning.aetherLevel
    }

    private func connectGraph(format: AVAudioFormat) {
        // Clear any prior routing before rewiring the two simultaneous selves.
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeInput(reverb)
        engine.disconnectNodeInput(delay)
        engine.disconnectNodeInput(aetherBus)
        engine.disconnectNodeInput(engine.mainMixerNode)

        // Presence: dry, close, centered.
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Æther: detuned, cathedral, echoed — arriving from the vast.
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: reverb, format: format)
        engine.connect(reverb, to: delay, format: format)
        engine.connect(delay, to: aetherBus, format: format)
        engine.connect(aetherBus, to: engine.mainMixerNode, format: format)
    }

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }
}