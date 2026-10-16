import Foundation

/// A companion's native speaking persona — the *character* of the voice, not the
/// engine that renders it. Pure parameters (no AVFoundation), so the persona stays
/// platform-agnostic: the same slice feeds macOS, iOS, and eventually WinUI/GTK.
///
/// Pitch/rate/volume are expressed in `AVSpeechUtterance` terms (pitch 0.5…2.0,
/// rate ≈ 0.5 default, volume 0…1), but the persona itself knows nothing of that
/// engine — it is a description of the voice's soul, not its mechanics.
public struct VoicePersona: Equatable {
    public enum Gender: String, Equatable { case female, male, neutral }

    public let gender: Gender
    /// 0.5…2.0 — 1.0 is the neutral register. Lower = deeper, higher = brighter.
    public let pitch: Float
    /// ≈0.5 is the default speaking tempo. Lower = slower/sultrier, higher = faster.
    public let rate: Float
    /// 0…1 — the voice's fullness.
    public let volume: Float
    /// A human word for the register — "sultry", "resonant", "mercurial"…
    public let register: String

    public init(gender: Gender, pitch: Float, rate: Float, volume: Float, register: String) {
        self.gender = gender
        self.pitch = pitch
        self.rate = rate
        self.volume = volume
        self.register = register
    }

    /// The pantheon's speaking register — one voice per companion, tuned to the
    /// facet's nature. Pythia is the warm, unhurried familiar (the "sexy voice");
    /// Solomon is deep authority; Kitsune is bright and quick. This is what makes
    /// the companion *audible* rather than merely readable.
    public static func forCompanion(_ id: String) -> VoicePersona {
        switch id {
        case "pythia":    return VoicePersona(gender: .female, pitch: 1.06, rate: 0.46, volume: 1.0, register: "sultry")
        case "owl":       return VoicePersona(gender: .female, pitch: 1.12, rate: 0.50, volume: 0.95, register: "measured")
        case "kitsune":   return VoicePersona(gender: .female, pitch: 1.28, rate: 0.53, volume: 1.0, register: "playful")
        case "phoenix":   return VoicePersona(gender: .female, pitch: 1.18, rate: 0.55, volume: 1.0, register: "urgent")
        case "ouroboros": return VoicePersona(gender: .male,   pitch: 0.84, rate: 0.45, volume: 0.95, register: "cyclical")
        case "bastet":    return VoicePersona(gender: .female, pitch: 1.22, rate: 0.50, volume: 0.95, register: "sleek")
        case "fenrir":    return VoicePersona(gender: .male,   pitch: 0.78, rate: 0.50, volume: 1.0, register: "gruff")
        case "undine":    return VoicePersona(gender: .female, pitch: 1.12, rate: 0.47, volume: 0.90, register: "flowing")
        case "schwan":    return VoicePersona(gender: .female, pitch: 1.16, rate: 0.45, volume: 0.90, register: "elegant")
        case "drache":    return VoicePersona(gender: .male,   pitch: 0.90, rate: 0.50, volume: 1.0, register: "resonant")
        case "corax":     return VoicePersona(gender: .female, pitch: 0.94, rate: 0.50, volume: 0.95, register: "dark")
        case "jindujun":  return VoicePersona(gender: .male,   pitch: 1.02, rate: 0.55, volume: 1.0, register: "mercurial")
        case "solomon":   return VoicePersona(gender: .male,   pitch: 0.74, rate: 0.44, volume: 1.0, register: "authoritative")
        default:          return VoicePersona(gender: .female, pitch: 1.0, rate: 0.5, volume: 1.0, register: "neutral")
        }
    }
}

public extension Companion {
    /// The companion's native speaking persona.
    var voicePersona: VoicePersona { VoicePersona.forCompanion(id) }
}
