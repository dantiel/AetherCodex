import SwiftUI
import Pythia

/// One message: user → trailing bubble; companion → glyph + name; Pythia → base flow.
struct MessageRow: View {
    let message: ChatMessage
    var isLastUserPrompt: Bool = false
    var onReplay: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .padding(12)
                    .background(AetherPalette.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                userMarkers
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if let name = message.speakerName {
            HStack(alignment: .top, spacing: 10) {
                Text(message.glyph).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(AetherPalette.accent)
                    MarkdownText(text: message.text)
                }
                Spacer()
                replayButton
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
                HStack(alignment: .top, spacing: 8) {
                    MarkdownText(text: message.text)
                    Spacer(minLength: 0)
                    replayButton
                }
            }
        }
    }

    @ViewBuilder
    private var replayButton: some View {
        if let onReplay {
            Button(action: onReplay) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// The three markers on the user's own prompt: edit (only the last prompt is
    /// *changeable*), reload (regenerate that turn), and delete (truncate here).
    @ViewBuilder
    private var userMarkers: some View {
        if onEdit != nil || onRegenerate != nil || onDelete != nil {
            HStack(spacing: 14) {
                if isLastUserPrompt, let onEdit {
                    marker("pencil", action: onEdit)
                }
                if let onRegenerate {
                    marker("arrow.clockwise", action: onRegenerate)
                }
                if let onDelete {
                    marker("trash", action: onDelete)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func marker(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
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