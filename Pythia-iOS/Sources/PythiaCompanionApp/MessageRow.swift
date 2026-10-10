import SwiftUI
import Pythia

/// One message: user → trailing bubble; companion → glyph + name; Pythia → base flow.
struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer()
                Text(message.text)
                    .padding(12)
                    .background(AetherPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
            }
        } else if let name = message.speakerName {
            HStack(alignment: .top, spacing: 10) {
                Text(message.glyph).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(AetherPalette.accent)
                    MarkdownText(text: message.text)
                }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                MarkdownText(text: message.text)
            }
        }
    }
}

/// Lightweight markdown → AttributedString, so answers render natively without a
/// web view (the manifest's WKWebView line is stale; Pythia is native SwiftUI).
struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
