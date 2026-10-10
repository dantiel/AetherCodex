import SwiftUI

// MARK: - Salomo Rex chat model

/// Salomo's own voice — a dedicated, multi-turn chat that talks *directly* to the
/// 👑 companion (not through default Pythia). Unlike the single-turn
/// `askCompanion` path, this carries a persistent conversation history and
/// Salomo's full toolset (seal_create, seal_run, task tools, …), so his planning
/// actually *acts* — it doesn't just describe.
///
/// The stream is a *part-stream* of Mnemosyne: `PythiaFlowStore` keys it under the
/// `salomon` stream name (a sibling ledger `pythia_flow.salomon.db`), so nothing
/// is stored twice and Salomo's history survives restarts independently of Pythia's.
@MainActor
final class SolomonChatModel: ObservableObject {
    @Published var flow: [FlowEntry] = []
    @Published var busy = false
    @Published var statusText: String?
    @Published var scrollAnchor = 0
    /// The in-flight instrumenta cluster of the running turn — the same
    /// `ToolGroup` Pythia weaves into its flow. On completion it is closed and
    /// appended to `flow`, so Salomo's ledger renders with Pythia's exact
    /// instrumenta display.
    @Published var toolGroup: ToolGroup? = nil
    /// Chips the user unfolded — mirrors Pythia's per-chip expansion ledger.
    @Published var expandedChipIDs: Set<UUID> = []
    /// The daemon's reported cwd, carried onto CLI chips like in Pythia.
    private var cliCwd: String = ""

    private var history: [[String: String]] = []
    private var boundContextRoot: String?
    private var hasRestored = false

    private static let streamName = "salomon"
    private let companionID = "solomon"

    var currentGlyph: String {
        pythiaCompanions.first { $0.id == companionID }?.glyph ?? "👑"
    }

    // MARK: Turn

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        trimHistory()
        let message = ChatMessage(role: "user", text: trimmed, glyph: currentGlyph)
        appendMessage(message)
        history.append(["role": "user", "content": trimmed])
        scrollAnchor += 1
        beginTurn()
    }

    private func beginTurn() {
        busy = true
        statusText = "💭 Salomo denkt…"
        toolGroup = nil
        expandedChipIDs = []
        let glyph = currentGlyph

        // While Salomo's turn runs (exclusively — the daemon worker is FIFO), the
        // stream frames route to *this* model. We save and restore Pythia's handler
        // so its flow is not polluted with Salomo's tool activity.
        let previousOnStream = RubyBridge.shared.onStream
        RubyBridge.shared.onStream = { [weak self] _, payload in
            guard let self, let payload else { return }
            Task { @MainActor in self.handleStream(payload) }
        }

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    RubyBridge.shared.onStream = previousOnStream
                }
            }
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                let reply = try await RubyBridge.shared.chatCompanion(
                    name: companionID, messages: history)
                let rawAnswer = reply.text ?? ""
                let finalText = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "The æther is silent." : rawAnswer
                var assistantEntry: [String: String] = ["role": "assistant", "content": finalText]
                if let rc = reply.reasoningContent, !rc.isEmpty {
                    assistantEntry["reasoning_content"] = rc
                }
                await MainActor.run {
                    self.statusText = nil
                    self.appendMessage(ChatMessage(role: "assistant", text: finalText,
                                                    glyph: glyph, reasoning: reply.reasoningContent))
                    // Companion voices answering through Salomo's turn (e.g. a
                    // delegated milestone's `_say`) land as their own glyph.
                    for say in reply.companionSays {
                        let name = pythiaCompanions.first { $0.id == say.name }?.displayName ?? say.name
                        self.appendMessage(ChatMessage(role: "assistant", text: say.message,
                                                       glyph: say.glyph, speakerName: name))
                    }
                    self.history.append(assistantEntry)
                    self.trimHistory()
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.statusText = nil
                    self.busy = false
                    self.appendMessage(ChatMessage(role: "assistant",
                                                   text: "⚠️ \(error.localizedDescription)",
                                                   glyph: glyph))
                }
            }
        }
    }

    // MARK: Streaming (light)

    private func handleStream(_ payload: [String: Any]) {
        let kind = payload["type"] as? String ?? ""
        let data = payload["data"] as? [String: Any] ?? [:]
        let uuid = payload["uuid"] as? String
        let toolId = payload["tool_id"] as? String ?? data["id"] as? String ?? data["tool_id"] as? String
        switch kind {
        case "thinking":
            statusText = "💭 \(data["message"] as? String ?? "thinking…")"
        case "thinking_complete":
            statusText = nil
        case "tool_starting", "tool_call":
            let name = (data["tool"] ?? data["name"]) as? String ?? "instrument"
            // Aegis surfaces as a full-width veil (see aegis_unveiled), not a chip.
            if name == "aegis" { break }
            if name == "run_command" {
                appendCliChip(args: instrumentaStringify(data["args"]), toolId: toolId)
            } else {
                appendTool(name, args: instrumentaStringify(data["args"]), uuid: uuid)
            }
        case "aegis_unveiled":
            appendAegisRevelation(data)
        case "tool_completed":
            let name = (data["tool"] ?? data["name"]) as? String ?? ""
            if name == "run_command" || name == "aegis" { break }  // aegis shown via aegis_unveiled
            completeTool(toolId: toolId, output: instrumentaStringify(data["result"]))
        case "command_executing":
            setCliChipCommand(data["command"] as? String ?? "", toolId: toolId)
        case "command_completed":
            if let cwd = data["cwd"] as? String, !cwd.isEmpty { cliCwd = cwd }
            completeCliChip(
                data["command"] as? String ?? "",
                output: data["content"] as? String ?? "",
                cwd: cliCwd,
                exitStatus: data["exit_status"] as? Int,
                toolId: toolId
            )
        case "system_error":
            appendSystemMessage(kind: kind, data: data, level: "error")
        case "peer_drift":
            appendSystemMessage(kind: kind, data: data, level: "warn")
        default:
            if InstrumentaStatus.statusKinds.contains(kind) {
                mergeToolStatus(kind: kind, data: data, uuid: uuid)
            }
        }
    }

    // MARK: Instrumenta weaving (shared ToolGroup vocabulary with Pythia)

    /// Merge an instrument call into the open group — Salomo's turn runs one
    /// group at a time, so there is a single live cluster, no flow search.
    private func appendTool(_ name: String, args: String = "", uuid: String? = nil) {
        appendChip(ToolChip(name: name, args: args, done: false, horologiumID: uuid))
    }

    /// Aegis surfaces as its own flow entry — a prominent context-shift veil,
    /// never a chip. Salomo shares Pythia's instrumenta vocabulary, so the two
    /// ledgers render the same course-change mark.
    private func appendAegisRevelation(_ data: [String: Any]) {
        closeToolGroup()
        let revelation = AegisRevelation.from(data)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.aegis(revelation))
        }
        persistFlow()
    }

    /// A system notice (error / drift warning) woven into the timeline at its
    /// chronological position — Salomo shares Pythia's veil so both ledgers
    /// render the same æther voice.
    private func appendSystemMessage(kind: String, data: [String: Any], level: String) {
        let raw = (data["message"] ?? data["error"]) as? String ?? ""
        let text = InstrumentaStatus.plainText(fromHTML: raw)
        guard !text.isEmpty else { return }
        closeToolGroup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.system(SystemMessage(text: text, level: level, kind: kind)))
        }
        persistFlow()
    }

    private func appendCliChip(args: String = "", toolId: String? = nil) {
        var chip = ToolChip(kind: .cli, name: "run_command", args: args,
                            done: false, command: "", cwd: cliCwd)
        chip.toolId = toolId
        appendChip(chip)
    }

    private func appendChip(_ chip: ToolChip) {
        var g = toolGroup ?? ToolGroup()
        g.tools.append(chip)
        toolGroup = g
    }

    /// Attach the real command to the open CLI chip (or create one if the
    /// tool_starting frame was missed).
    private func setCliChipCommand(_ cmd: String, toolId: String? = nil) {
        guard var g = toolGroup else {
            appendCliChip(toolId: toolId)
            return
        }
        if let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done && (toolId == nil || $0.toolId == toolId) }) {
            g.tools[chipIdx].command = cmd
        } else {
            appendCliChip(toolId: toolId)
            return
        }
        toolGroup = g
    }

    /// Fill the open CLI chip with command output, cwd and exit status.
    private func completeCliChip(_ cmd: String, output: String, cwd: String, exitStatus: Int?, toolId: String? = nil) {
        guard var g = toolGroup,
              let chipIdx = g.tools.lastIndex(where: { $0.kind == .cli && !$0.done && (toolId == nil || $0.toolId == toolId) }) else { return }
        if !cmd.isEmpty { g.tools[chipIdx].command = cmd }
        g.tools[chipIdx].output = output
        g.tools[chipIdx].cwd = cwd
        g.tools[chipIdx].exitStatus = exitStatus
        g.tools[chipIdx].done = true
        g.tools[chipIdx].status = nil
        toolGroup = g
    }

    /// Mark the newest unfinished *instrument* chip as completed. CLI chips are
    /// completed via command_completed, not here.
    private func completeTool(toolId: String? = nil, output: String) {
        guard var g = toolGroup else { return }
        var chipIdx: Int? = nil
        if let toolId {
            chipIdx = g.tools.lastIndex(where: { $0.toolId == toolId })
        }
        if chipIdx == nil {
            chipIdx = g.tools.lastIndex(where: { $0.kind == .instrument && !$0.done })
        }
        guard let ci = chipIdx else { return }
        g.tools[ci].done = true
        g.tools[ci].output = output
        g.tools[ci].status = nil
        toolGroup = g
    }

    /// Merge a granular Horologium frame into the in-flight instrument chip —
    /// the same minified line + detail Pythia shows.
    private func mergeToolStatus(kind: String, data: [String: Any], uuid: String?) {
        guard var g = toolGroup,
              let cIdx = g.tools.lastIndex(where: { $0.kind == .instrument && !$0.done }) else { return }
        var chip = g.tools[cIdx]
        if let uuid, !uuid.isEmpty { chip.horologiumID = uuid }
        let (status, detail) = InstrumentaStatus.mergeText(kind: kind, data: data)
        if let status { chip.status = status }
        if let detail { chip.detail = detail }
        if let rawMessage = data["message"] as? String, !rawMessage.isEmpty {
            chip.message = InstrumentaStatus.plainText(fromHTML: rawMessage)
        }
        g.tools[cIdx] = chip
        toolGroup = g
    }

    /// Close the live group into the persisted flow — the completed instrumenta
    /// cluster becomes a permanent ledger entry like in Pythia.
    private func closeToolGroup() {
        guard let g = toolGroup, !g.tools.isEmpty else {
            toolGroup = nil
            return
        }
        var closed = g
        closed.closed = true
        flow.append(.toolGroup(closed))
        toolGroup = nil
    }

    /// Toggle the live group's collapsed state.
    func toggleToolGroup(_ id: UUID) {
        if let g = toolGroup, g.id == id {
            var g2 = g
            g2.expanded.toggle()
            toolGroup = g2
            return
        }
        guard let idx = flow.firstIndex(where: { if case .toolGroup(let g) = $0 { return g.id == id } else { return false } }),
              case .toolGroup(let group) = flow[idx] else { return }
        var g = group
        g.expanded.toggle()
        flow[idx] = .toolGroup(g)
        persistFlow()
    }

    /// Toggle a single tool chip's minimized/expanded state (shared across the
    /// live group and every persisted one).
    func toggleToolChip(_ id: UUID) {
        var next = expandedChipIDs
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        expandedChipIDs = next
    }

    // MARK: Flow

    private func appendMessage(_ message: ChatMessage) {
        // Any open instrumenta run closes before text lands — the group becomes
        // a permanent ledger entry, the message follows it.
        closeToolGroup()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            flow.append(.message(message))
        }
        persistFlow()
    }

    private func trimHistory() {
        let maxEntries = 8
        if history.count > maxEntries {
            history.removeFirst(history.count - maxEntries)
        }
    }

    // MARK: Persistence

    private func persistFlow() {
        _ = PythiaFlowStore.shared.save(
            cwd: "", flow: flow, history: history,
            forContext: boundContextRoot, stream: Self.streamName)
    }

    func restoreIfNeeded() {
        guard !hasRestored else { return }
        hasRestored = true
        boundContextRoot = AetherContext.shared.root
        if let snap = PythiaFlowStore.shared.load(forContext: boundContextRoot, stream: Self.streamName) {
            flow = snap.flow
            history = snap.history
        }
    }

    func contextDidChange(from oldRoot: String?, to newRoot: String?) {
        guard boundContextRoot != newRoot else { return }
        _ = PythiaFlowStore.shared.save(
            cwd: "", flow: flow, history: history,
            forContext: boundContextRoot ?? oldRoot, stream: Self.streamName)
        boundContextRoot = newRoot
        if let snap = PythiaFlowStore.shared.load(forContext: newRoot, stream: Self.streamName) {
            flow = snap.flow
            history = snap.history
        } else {
            flow = []
            history = []
        }
    }
}

// MARK: - Salomo panel

/// The 👑 face of the trailing pane: Salomo's own chat above, the Siegel
/// milestone temple below. Both halves are independently collapsible — the chat
/// is toggleable so one can edit the seal without bouncing back to Pythia.
struct SolomonPanel: View {
    @StateObject private var chat = SolomonChatModel()
    @ObservedObject private var aetherContext = AetherContext.shared
    @Environment(\.pythiaPalette) private var palette
    @State private var showChat = true
    @State private var showMilestones = true

    var body: some View {
        VStack(spacing: 0) {
            SolomonToolbar(showChat: $showChat, showMilestones: $showMilestones)
            Divider().opacity(0.4)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    SolomonChatView(model: chat)
                        .frame(height: chatHeight(geo.size.height))
                    if showChat && showMilestones {
                        Divider().opacity(0.4)
                    }
                    SiegelPanel()
                        .frame(height: milestoneHeight(geo.size.height))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { chat.restoreIfNeeded() }
        .onChange(of: aetherContext.root) { oldRoot, newRoot in
            chat.contextDidChange(from: oldRoot, to: newRoot)
        }
    }

    private func chatHeight(_ total: CGFloat) -> CGFloat {
        if !showChat { return 0 }
        if !showMilestones { return total }
        return total / 2
    }

    private func milestoneHeight(_ total: CGFloat) -> CGFloat {
        if !showMilestones { return 0 }
        if !showChat { return total }
        return total / 2
    }
}

// MARK: - Toolbar

private struct SolomonToolbar: View {
    @Binding var showChat: Bool
    @Binding var showMilestones: Bool
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text("👑").font(.system(size: 13))
            Text("Salomo Rex")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.foregroundColor)
            Spacer(minLength: 0)
            sectionToggle("bubble.left.and.bubble.right.fill", label: "Chat", isOn: $showChat)
            sectionToggle("list.bullet.rectangle.portrait", label: "Meilensteine", isOn: $showMilestones)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sectionToggle(_ systemImage: String, label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isOn.wrappedValue ? palette.accentColor.opacity(0.25) : Color.clear,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isOn.wrappedValue ? palette.accentColor.opacity(0.5) : .white.opacity(0.08),
                        lineWidth: 0.75
                    )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? palette.accentColor : palette.foregroundColor.opacity(0.7))
        .help("\(label) anzeigen / ausblenden")
    }
}

// MARK: - Chat view

private struct SolomonChatView: View {
    @ObservedObject var model: SolomonChatModel
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.flow.isEmpty && model.toolGroup == nil {
                            emptyHint
                        }
                        ForEach(model.flow) { entry in
                            switch entry {
                            case .message(let m):
                                SolomonMessageRow(message: m)
                            case .toolGroup(let group):
                                ToolGroupView(group: group,
                                              expandedChipIDs: model.expandedChipIDs,
                                              onToggle: { model.toggleToolGroup(group.id) },
                                              onToggleChip: { model.toggleToolChip($0) })
                            case .cli:
                                EmptyView()
                            case .aegis(let aegis):
                                AegisBlock(revelation: aegis)
                            case .system(let system):
                                SystemMessageRow(message: system)
                            }
                        }
                        if let liveGroup = model.toolGroup {
                            ToolGroupView(group: liveGroup,
                                          expandedChipIDs: model.expandedChipIDs,
                                          onToggle: { model.toggleToolGroup(liveGroup.id) },
                                          onToggleChip: { model.toggleToolChip($0) })
                        }
                        Color.clear.frame(height: 1).id("solomon-bottom")
                    }
                    .padding(10)
                }
                .onChange(of: model.scrollAnchor) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("solomon-bottom", anchor: .bottom)
                    }
                }
            }

            if let status = model.statusText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            SolomonInputBar(model: model)
                .padding(10)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("👑 Salomo Rex")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foregroundColor)
            Text("Sprich mit dem König — er zerlegt große Ziele in Meilensteine und gießt sie direkt in ein Siegel. »Salomo, plane den AppStore-Release.«")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Message row

private struct SolomonMessageRow: View {
    let message: ChatMessage
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .font(Font(ThemeRegistry.shared.current.pythia.proseFont))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(palette.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.accentColor.opacity(0.35), lineWidth: 0.75))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = message.speakerName {
                    HStack(spacing: 4) {
                        Text(message.glyph).font(.system(size: 11))
                        Text(speaker)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accentColor)
                    }
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                MarkdownBody(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Input bar

private struct SolomonInputBar: View {
    @ObservedObject var model: SolomonChatModel
    @State private var text = ""
    @Environment(\.pythiaPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            TextField("Salomo ansprechen …", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(send)
                .disabled(model.busy)
            Button(action: send) {
                Image(systemName: model.busy ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(canSend ? palette.accentColor : palette.foregroundColor.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || model.busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07), lineWidth: 0.75))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        model.send(trimmed)
    }
}