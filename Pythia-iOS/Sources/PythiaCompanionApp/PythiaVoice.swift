import AVFoundation
import SwiftUI
import Pythia

/// The voice of the oracle — an `AVSpeechSynthesizer` tuned to be *felt*, not just
/// heard. This is the layer that lets Pythia surpass Siri and ChatGPT's canned
/// voices: premium-quality synthesis, per-companion personas, language-matching,
/// and sentence-level enqueuing so the first words arrive before the answer
/// finishes thinking itself into text.
/// How the oracle's voice is rendered. `.natural` is the plain synthesizer;
/// `.aetheric` is the priestess voice — presence and æther at once.
enum VoiceMode: Equatable { case natural, aetheric }

@MainActor
final class PythiaVoice: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    enum State: Equatable { case idle, speaking }

    @Published private(set) var state: State = .idle
    @Published var autoSpeak = false
    /// The priestess speaks ætheric by default — close *and* from the internet.
    @Published var mode: VoiceMode = .aetheric

    private let synthesizer = AVSpeechSynthesizer()
    private let aetheric = AethericVoiceRenderer()
    private var pendingCount = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// Speak an answer. Markdown is distilled into prosody; the text is split into
    /// sentences and enqueued so natural pauses fall where the author intended,
    /// and the first sentence sounds immediately.
    func speak(_ text: String, persona: VoicePersona) {
        let clean = Self.prosody(text)
        guard !clean.isEmpty else { return }

        stop()
        let language = Self.dominantLanguage(of: clean) ?? Locale.current.language.languageCode?.identifier ?? "en-US"
        let voice = Self.bestVoice(for: language, persona: persona)

        switch mode {
        case .natural:
            let sentences = Self.sentences(in: clean)
            for sentence in sentences {
                let utterance = AVSpeechUtterance(string: sentence)
                utterance.voice = voice
                utterance.pitchMultiplier = persona.pitch
                utterance.rate = persona.rate
                utterance.volume = persona.volume
                utterance.preUtteranceDelay = 0.02
                utterance.postUtteranceDelay = 0.08
                synthesizer.speak(utterance)
            }
            pendingCount = sentences.count
            state = .speaking

        case .aetheric:
            state = .speaking
            aetheric.speak(clean, voice: voice, persona: persona) { [weak self] in
                self?.state = .idle
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        aetheric.stop()
        pendingCount = 0
        state = .idle
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        state = .speaking
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 { state = .idle }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 { state = .idle }
    }

    // MARK: - Prosody

    /// Distill markdown into speakable prose: strip fences, inline code, links,
    /// emphasis markers, list bullets, headings, and emoji; collapse whitespace.
    /// The oracle speaks clean, unbroken thought — no asterisks in the breath.
    static func prosody(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*[-*•]\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^\\s*\\d+[.)]\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Strip pictographs/emoji so the synthesizer never stumbles on a glyph.
        let stripped = s.unicodeScalars.filter { scalar in
            !(0x1F000...0x1FAFF).contains(scalar.value)
                && !(0x2600...0x27BF).contains(scalar.value)
                && !(0xFE00...0xFE0F).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentences(in text: String) -> [String] {
        var parts: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences]) { substring, _, _, _ in
            if let substring { parts.append(String(substring)) }
        }
        return parts.isEmpty ? [text] : parts
    }

    /// Detect the dominant language of the answer, so the voice matches the
    /// tongue the oracle chose — German answers in German, Chinese in Chinese.
    static func dominantLanguage(of text: String) -> String? {
        let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
        tagger.string = text
        return tagger.dominantLanguage
    }

    /// Choose the best available voice: premium > enhanced > default, matching the
    /// persona's gender first, then falling back across the language's voices.
    static func bestVoice(for language: String, persona: VoicePersona) -> AVSpeechSynthesisVoice? {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let all = AVSpeechSynthesisVoice.speechVoices()
        func voiceBase(_ v: AVSpeechSynthesisVoice) -> String {
            v.language.split(separator: "-").first.map(String.init) ?? v.language
        }

        var candidates = all.filter { voiceBase($0) == base }
        if candidates.isEmpty { candidates = all }

        let wantedGender: AVSpeechSynthesisVoiceGender? =
            persona.gender == .female ? .female : persona.gender == .male ? .male : nil

        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default] {
            if let wantedGender, let match = candidates.first(where: { $0.quality == quality && $0.gender == wantedGender }) {
                return match
            }
            if let match = candidates.first(where: { $0.quality == quality }) { return match }
        }
        return AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}