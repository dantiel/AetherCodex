import SwiftUI
import Pythia

/// Pythia's presence made visible — a breathing orb. It rests while she listens
/// and swells while she speaks; the amplitude is the voice's breath. The glyph is
/// the companion's face, floating in its own soft halo.
struct VoiceBreathView: View {
    let speaking: Bool
    let glyph: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = speaking ? (0.5 + 0.5 * abs(sin(t * 3.2))) : 0.12
            let radius = 20.0 + breath * 12.0

            ZStack {
                Circle()
                    .fill(AetherPalette.accent.opacity(0.10 + breath * 0.22))
                    .frame(width: radius * 2, height: radius * 2)
                    .blur(radius: 7)

                Circle()
                    .fill(AetherPalette.accent.opacity(speaking ? 0.72 : 0.5))
                    .frame(width: 34, height: 34)

                Text(glyph)
                    .font(.system(size: 16))
            }
            .frame(width: 44, height: 44)
        }
        .animation(.easeInOut(duration: 0.25), value: speaking)
    }
}
