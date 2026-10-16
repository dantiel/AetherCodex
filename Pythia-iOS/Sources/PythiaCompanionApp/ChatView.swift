import SwiftUI
import Pythia

/// Second face — the conversation. The chat is the whole interface; chrome is
/// withdrawn to a single companion chip and a quiet input bar.
struct ChatView: View {
    @ObservedObject var model: PythiaCompanionModel

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages) { message in
                            MessageRow(
                                message: message,
                                onReplay: message.role == "assistant"
                                    ? { model.voice.speak(message.text, persona: model.activeCompanion.voicePersona) }
                                    : nil
                            )
                            .id(message.id)
                        }
                        if model.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("the oracle thinks…").font(.caption).foregroundStyle(.secondary)
                            }
                            .id("busy")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.count) { _, _ in
                    withAnimation { scrollToBottom(proxy) }
                }
                .onChange(of: model.busy) { _, _ in
                    withAnimation { scrollToBottom(proxy) }
                }
            }

            inputBar
        }
        .background(AetherPalette.surface)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = model.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        } else if model.busy {
            proxy.scrollTo("busy", anchor: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(pythiaCompanions) { voice in
                    Button {
                        model.companionID = voice.id
                    } label: {
                        if model.companionID == voice.id {
                            Label(voice.displayName, systemImage: "checkmark")
                        } else {
                            Text("\(voice.glyph) \(voice.displayName)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.activeCompanion.glyph)
                    Text(model.activeCompanion.displayName).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AetherPalette.companionBubble, in: Capsule())
            }

            Spacer()

            VoiceBreathView(
                speaking: model.voice.state == .speaking,
                glyph: model.activeCompanion.glyph
            )

            Button {
                model.voice.autoSpeak.toggle()
                if model.voice.autoSpeak {
                    model.voice.speak(
                        "I am listening.",
                        persona: model.activeCompanion.voicePersona
                    )
                } else {
                    model.voice.stop()
                }
            } label: {
                Image(systemName: model.voice.autoSpeak ? "speaker.wave.3.fill" : "speaker.slash")
                    .foregroundStyle(model.voice.autoSpeak ? AetherPalette.accent : Color.secondary)
            }

            Button {
                model.disconnect()
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Speak to the oracle…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

                Button {
                    Task { await model.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(AetherPalette.accent, in: Circle())
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}