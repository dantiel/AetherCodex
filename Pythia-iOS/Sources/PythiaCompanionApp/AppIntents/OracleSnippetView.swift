import SwiftUI

/// The oracle's answer, rendered as a glanceable snippet. This is the channel's
/// success face — glyph, voice, and the calculated reply, nothing else.
struct OracleAnswerSnippet: View {
    let glyph: String
    let voice: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(glyph)
                Text(voice)
                    .font(.headline)
            }
            Text(answer)
                .font(.body)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The channel's failure face — the oracle is unreachable. Non-modal, honest.
struct OracleErrorSnippet: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Oracle unreachable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-out of the aether's current reasoning state (`/aether/aegis`).
struct AegisStateSnippet: View {
    let thinking: String
    let temperature: Double
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Æther state", systemImage: "brain")
                .font(.headline)
            if !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .lineLimit(4)
            }
            Text("thinking · \(thinking) · temp \(temperature, specifier: "%.1f")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
