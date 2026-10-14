import SwiftUI

/// The Ægis — the shield that mirrors the divine light. At night it reflects the
/// fixed stars (the permanent principles); at day it reflects the sun (the
/// active course). The current course — the granted privileges — is written
/// upon its face.
struct AegisShieldView: View {
    @ObservedObject var model: AegisModel
    @State private var pulse = false

    private let facets = AegisFacetModel.all

    var body: some View {
        ZStack {
            AegisBackdrop()

            VStack(spacing: 28) {
                shield

                Text("At night it mirrors the fixed stars; at day it mirrors the sun.\nThe current course is written upon its face.")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                facetList
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
        }
        .frame(minWidth: 520, minHeight: 620)
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
    }

    // MARK: Shield

    private var shield: some View {
        let ratio = Double(model.grantedCount) / Double(facets.count)
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.10 + 0.16 * ratio),
                            .clear,
                        ],
                        center: .center, startRadius: 0, endRadius: 90
                    )
                )
                .frame(width: 190, height: 190)
                .blur(radius: 1)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            .white.opacity(0.10 + 0.5 * ratio),
                            .clear, .white.opacity(0.10 + 0.5 * ratio),
                        ],
                        center: .center
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 168, height: 168)

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 150, height: 150)

            VStack(spacing: 4) {
                Text(sunOrStars(ratio))
                    .font(.system(size: 40))
                    .scaleEffect(pulse ? 1.06 : 1.0)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulse)

                Text("\(model.grantedCount) / \(facets.count)")
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))

                Text("lights reflected")
                    .font(.system(size: 10, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .onAppear { pulse = true }
    }

    private func sunOrStars(_ ratio: Double) -> String {
        if ratio >= 1.0 { return "☀️" }
        if ratio > 0.0 { return "🌗" }
        return "🌌"
    }

    // MARK: Facets

    private var facetList: some View {
        VStack(spacing: 10) {
            ForEach(facets) { facet in
                AegisFacetRow(facet: facet, granted: model.granted(facet.id)) {
                    model.request(facet.id)
                }
            }
        }
    }
}

// MARK: - Facet Row

private struct AegisFacetRow: View {
    let facet: AegisFacetModel
    let granted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(facet.glyph)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(.white.opacity(granted ? 0.14 : 0.05))
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(granted ? 0.5 : 0.15), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(facet.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(granted ? 0.95 : 0.7))
                    if granted {
                        Text("reflecting")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                }
                Text(facet.light)
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                    .italic()
                Text(facet.blurb)
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onRequest) {
                Text(granted ? "Granted" : "Grant")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? Color.white.opacity(0.55) : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(granted ? Color.white.opacity(0.06) : Color.white.opacity(0.16))
                    )
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(granted ? 0.12 : 0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(granted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Backdrop

private struct AegisBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.06),
                    Color(red: 0.05, green: 0.04, blue: 0.14),
                    Color(red: 0.02, green: 0.03, blue: 0.09),
                ],
                startPoint: .top, endPoint: .bottom
            )

            Canvas { context, size in
                var rng = SeededGenerator(seed: 0xA3615)
                for _ in 0..<90 {
                    let x = CGFloat.random(in: 0..<size.width, using: &rng)
                    let y = CGFloat.random(in: 0..<size.height, using: &rng)
                    let r = CGFloat.random(in: 0.4...1.4, using: &rng)
                    let a = CGFloat.random(in: 0.08...0.6, using: &rng)
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(a))
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A tiny deterministic PRNG so the star field is stable across redraws.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
