import SwiftUI
import Pythia

/// The native face of the agent's `ask_user` instrument on iOS. The Mac panel
/// reads the live stream; the phone polls `/aether/pending` and surfaces the same
/// consultation here — confirm/select buttons when options exist, a free-form
/// field otherwise — then answers via `/aether/respond`.
struct AskUserSheet: View {
    let question: PendingQuestion
    let onAnswer: (String) -> Void

    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Pythia seeks your counsel", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(AetherPalette.accent)

            Text(question.message)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !question.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(question.options, id: \.self) { option in
                        Button(option) { onAnswer(option) }
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(AetherPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Cancel") { onAnswer("__cancel__") }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Your answer…", text: $freeText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Cancel") { onAnswer("__cancel__") }
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Answer") { onAnswer(freeText) }
                        .fontWeight(.semibold)
                        .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}
