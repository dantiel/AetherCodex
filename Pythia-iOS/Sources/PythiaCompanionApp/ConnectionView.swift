import SwiftUI
import Pythia

/// First face — discover the Mac's daemon by LAN address, or pick a live peer.
struct ConnectionView: View {
    @ObservedObject var model: PythiaCompanionModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("🐍")
                .font(.system(size: 64))

            Text("Pythia")
                .font(.largeTitle.weight(.semibold))

            Text("The oracle travels with you.\nSummon the Mac's context to speak.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                HStack {
                    TextField("Mac address (e.g. 192.168.1.10)", text: $model.host)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Button(model.connection == .discovering ? "…" : "Scan") {
                        Task { await model.discover() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.host.isEmpty || model.connection == .discovering)
                }

                if !model.peers.isEmpty {
                    ForEach(model.peers) { peer in
                        Button {
                            model.connect(to: peer)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(peer.busy ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    Text(peer.name).font(.headline)
                                    Text("\(peer.host):\(peer.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if peer.busy { Text("busy").font(.caption).foregroundStyle(.orange) }
                            }
                            .padding(10)
                            .background(AetherPalette.companionBubble, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 400)

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding()
    }
}
