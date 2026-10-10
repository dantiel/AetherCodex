import AppKit
import SwiftUI

// MARK: - Aegis State

/// The live Aegis orientation — summary, tags, thinking depth, temperature,
/// working directory and the recalled notes. Parsed from the daemon's `aegis`
/// instrument payload, shared between the inline Pythia widget and its detached
/// floating window.
struct AegisState: Equatable {
    var summary: String
    var tags: [String]
    var thinking: String?
    var temperature: Double?
    var workingDir: String?
    var notes: [AegisNote]

    init(summary: String = "",
         tags: [String] = [],
         thinking: String? = nil,
         temperature: Double? = nil,
         workingDir: String? = nil,
         notes: [AegisNote] = []) {
        self.summary = summary
        self.tags = tags
        self.thinking = thinking
        self.temperature = temperature
        self.workingDir = workingDir
        self.notes = notes
    }

    init(from dict: [String: Any]) {
        summary = dict["summary"] as? String ?? ""
        if let arr = dict["tags"] as? [String] {
            tags = arr
        } else if let str = dict["tags"] as? String, !str.isEmpty {
            tags = str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            tags = []
        }
        thinking = dict["thinking"] as? String
        temperature = (dict["temperature"] as? NSNumber)?.doubleValue
        workingDir = dict["working_dir"] as? String
        if let rawNotes = dict["notes"] as? [[String: Any]] {
            notes = rawNotes.map { AegisNote(from: $0) }
        } else {
            notes = []
        }
    }

    /// The companion facets summoned into the orientation (`facet:owl` → `owl`).
    var facetTags: [String] {
        tags.filter { $0.hasPrefix("facet:") }.map { String($0.dropFirst("facet:".count)) }
    }

    /// Non-facet tags — plain orientation labels (release, appstore, …).
    var plainTags: [String] {
        tags.filter { !$0.hasPrefix("facet:") }
    }

    var isEmpty: Bool {
        summary.isEmpty && tags.isEmpty && thinking == nil && temperature == nil
            && workingDir == nil && notes.isEmpty
    }

    /// Field-wise merge that never wipes non-empty content with empty content.
    /// This is the guard behind "reload must never empty the widget": a fetched
    /// field only replaces an existing one when it actually carries data.
    func merged(with other: AegisState) -> AegisState {
        AegisState(
            summary: other.summary.isEmpty ? summary : other.summary,
            tags: other.tags.isEmpty ? tags : other.tags,
            thinking: other.thinking ?? thinking,
            temperature: other.temperature ?? temperature,
            workingDir: other.workingDir ?? workingDir,
            notes: other.notes.isEmpty ? notes : other.notes
        )
    }
}

/// Companion facet → glyph. Keeps the widget's pantheon chips in the same
/// visual language as the companion bubbles elsewhere in Pythia.
enum FacetGlyph {
    static let map: [String: String] = [
        "owl": "🦉", "kitsune": "🦊", "phoenix": "🔥", "ouroboros": "🐍",
        "bastet": "🐈", "fenrir": "🐺", "undine": "🌊", "schwan": "🦢",
        "drache": "🐉", "corax": "⬛", "jindujun": "☁️", "solomon": "👑"
    ]

    static func glyph(for facet: String) -> String {
        map[facet] ?? "✨"
    }
}

/// One companion summoned into the Ægis course — the visible face of the
/// hidden `Coniunctio` context-builder in the oracle. The team travels inside
/// the orientation (facet tags + summary): the same voices the daemon weaves
/// into a turn's context, only here made legible.
struct AegisConjunctionMember: Identifiable, Equatable {
    let id = UUID()
    let companionID: String   // facet id, e.g. "owl", "corax"
    let glyph: String
    let name: String
    let intent: String?       // nil = contextless summon
}

// MARK: - Shared Model

/// One orientation, two windows. The inline Pythia widget and the detached
/// floating window both observe this singleton, so a refresh in one place —
/// on appear, after a course shift, or when the daemon unveils a new
/// course — re-orients both at once.
final class AegisWidgetModel: ObservableObject {
    static let shared = AegisWidgetModel()

    /// Posted when the flash model has drafted a fresh course plan; the plan
    /// rides in `userInfo`. The widget owns the data, the conversation owns the
    /// trace — Pythia weaves it into the flow as a veil.
    static let coursePlanDidLand = Notification.Name("aethercodex.aegis.coursePlanDidLand")

    private static let recallLimitKey = "aegis.recallLimit"

    @Published var state = AegisState()
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// The conjoined team — the assembled intention the next turn's context
    /// carries. Mirrored into the daemon's Aegis on every change.
    @Published var conjunction: [AegisConjunctionMember] = []
    /// The flash-drafted course plan ("wir nehmen kurz Kurs auf…").
    @Published var coursePlan: String? = nil
    @Published var coursePlanBusy = false
    /// How many Mnemosyne notes the Coniunctio assembler recalls into this
    /// orientation — the one depth knob the hidden context-builder exposes.
    @Published var recallLimit: Int = 8

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.recallLimitKey)
        if saved > 0 { recallLimit = saved }
    }

    func refresh() async {
        await MainActor.run { isLoading = true }
        do {
            if let dict = try await RubyBridge.shared.getAegis(limit: recallLimit) {
                let fetched = AegisState(from: dict)
                await MainActor.run {
                    // Never empty: fetched content wins, empty content is kept.
                    state = state.merged(with: fetched)
                    errorMessage = nil
                }
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
        await MainActor.run { isLoading = false }
    }

    func setTemperature(_ value: Double) async {
        _ = try? await RubyBridge.shared.updateAegis(temperature: value)
        await refresh()
    }

    func setThinking(_ level: String) async {
        _ = try? await RubyBridge.shared.updateAegis(thinking: level)
        await refresh()
    }

    /// Change the recall depth and re-assemble the orientation from it.
    func setRecallLimit(_ value: Int) {
        let clamped = min(max(value, 1), 40)
        guard clamped != recallLimit else { return }
        recallLimit = clamped
        UserDefaults.standard.set(clamped, forKey: Self.recallLimitKey)
        Task { await refresh() }
    }

    /// Conjoin a companion into the Ægis course. Returns false when the voice
    /// already holds a seat (dedupe by facet), so the caller never opens a
    /// second turn for one intention.
    @discardableResult
    func conjoin(_ member: AegisConjunctionMember) -> Bool {
        guard !conjunction.contains(where: { $0.companionID == member.companionID }) else { return false }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            conjunction.append(member)
        }
        persistConjunction()
        if conjunction.count > 1 { draftCoursePlan() }
        return true
    }

    /// Dissolve the course — in both worlds.
    func clearConjunction() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            conjunction = []
            coursePlan = nil
            coursePlanBusy = false
        }
        // The course summary and its facet tags are this model's own
        // inscription — withdraw them locally too: the merge guard that keeps
        // the mirror from ever going blank would otherwise let the dissolved
        // course linger in the orientation.
        state.summary = ""
        state.tags = state.tags.filter { !$0.hasPrefix("facet:") }
        persistConjunction()
    }

    /// Mirror the team into the daemon's Aegis: one facet tag per summoned
    /// companion plus one shared summary. This is exactly what the Coniunctio
    /// assembler reads when it weaves the next turn's context.
    private func persistConjunction() {
        let tags = conjunction.map { "facet:\($0.companionID)" }
        let roster = conjunction.map { "\($0.glyph) \($0.name)" }.joined(separator: ", ")
        let summary = conjunction.isEmpty ? "" : "Coniunctio — \(roster) halten einen Kurs."
        Task {
            _ = try? await RubyBridge.shared.updateAegis(summary: summary, tags: tags)
            await AegisWidgetModel.shared.refresh()
        }
    }

    /// "Wir nehmen kurz Kurs auf…" — the flash model fuses the team's intents
    /// into a single brief course. Fuel-aware: the daemon picks the cheapest
    /// model that still flies (`flash_auto`).
    func draftCoursePlan() {
        guard !coursePlanBusy, conjunction.count > 1 else { return }
        coursePlanBusy = true
        coursePlan = nil
        let members = conjunction
        let companions = members.map { "\($0.glyph) \($0.name)" }
        let intents = members.compactMap { $0.intent }
        Task {
            let plan = try? await RubyBridge.shared.conjureCourse(
                companions: companions, intents: intents
            )
            await MainActor.run {
                AegisWidgetModel.shared.coursePlanBusy = false
                guard let plan, !plan.isEmpty else { return }
                AegisWidgetModel.shared.coursePlan = plan
                NotificationCenter.default.post(
                    name: AegisWidgetModel.coursePlanDidLand, object: nil,
                    userInfo: ["plan": plan]
                )
            }
        }
    }
}

// MARK: - Widget (inline)

/// A compact veil strip in Pythia's bottom chrome: the current Aegis
/// orientation as a one-line summary plus facet chips, with a detach affordance
/// that lifts it into its own floating glass window.
struct AegisWidgetView: View {
    @ObservedObject var model: AegisWidgetModel
    @State private var expanded = false

    init(model: AegisWidgetModel = .shared) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if expanded {
                Divider().opacity(0.35)
                AegisDetailView(model: model)
            }
        }
        .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.indigo.opacity(0.22), lineWidth: 0.5)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.indigo)
                    Text("Aegis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
            }
            .buttonStyle(.plain)

            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
            }

            summaryLine

            if !model.state.facetTags.isEmpty {
                facetChips
            }

            Spacer(minLength: 0)

            meta

            refreshButton
            detachButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var summaryLine: some View {
        if !model.state.summary.isEmpty {
            Text(model.state.summary)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.state.summary)
        } else if let error = model.errorMessage {
            Text(error)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(error)
        } else if !model.isLoading {
            Text("Aegis is still — no course set.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var facetChips: some View {
        HStack(spacing: 3) {
            ForEach(model.state.facetTags, id: \.self) { facet in
                Text(FacetGlyph.glyph(for: facet))
                    .font(.system(size: 9))
                    .frame(width: 18, height: 18)
                    .background(.indigo.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(.indigo.opacity(0.20), lineWidth: 0.5))
                    .help(facet)
            }
        }
    }

    @ViewBuilder private var meta: some View {
        if let thinking = model.state.thinking {
            Text("thinking: \(thinking)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        if let temperature = model.state.temperature {
            Text("temp \(String(format: "%.1f", temperature))")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh Aegis")
    }

    private var detachButton: some View {
        Button {
            AegisWidgetController.shared.toggle()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Detach Aegis widget")
    }

}

// MARK: - Detail (shared by inline-expanded and detached window)

/// The full Aegis mirror: summary, working directory, plain tags, the recalled
/// notes, and editable parameters (temperature + thinking) that push straight
/// back to the daemon.
struct AegisDetailView: View {
    @ObservedObject var model: AegisWidgetModel

    @State private var temperature: Double = 1.0
    @State private var thinking: String = "normal"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AegisSection(title: "Orientation") {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.state.summary.isEmpty {
                        Text(model.state.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let wd = model.state.workingDir, !wd.isEmpty {
                        Label(wd, systemImage: "folder")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(wd)
                    }

                    if !model.state.plainTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(model.state.plainTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.indigo.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().strokeBorder(.indigo.opacity(0.18), lineWidth: 0.5))
                                }
                            }
                        }
                    }
                }
            }

            if !model.conjunction.isEmpty {
                AegisSection(title: "Course",
                             badge: "\(model.conjunction.count)",
                             accessory: AnyView(clearCourseButton)) {
                    courseBody
                }
            }

            AegisSection(title: "Parameters", initiallyOpen: false) {
                controls
            }

            AegisSection(title: "Recalled notes",
                         badge: "\(model.state.notes.count)",
                         accessory: AnyView(recallAdjuster)) {
                notesBody
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { syncFromModel() }
        .onChange(of: model.state.temperature) { _, _ in syncFromModel() }
        .onChange(of: model.state.thinking) { _, _ in syncFromModel() }
    }

    // MARK: Sections

    /// The assembled team: who holds a seat, the intentions they brought, and
    /// the flash-drafted course that binds them.
    @ViewBuilder private var courseBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.conjunction) { member in
                        HStack(spacing: 4) {
                            Text(member.glyph).font(.system(size: 10))
                            Text(member.name).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.indigo.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.indigo.opacity(0.18), lineWidth: 0.5))
                        .help(member.intent ?? member.name)
                    }
                }
            }

            ForEach(model.conjunction.filter { $0.intent != nil }) { member in
                HStack(alignment: .top, spacing: 5) {
                    Text(member.glyph).font(.system(size: 9))
                    Text(member.intent ?? "")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.coursePlanBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                    Text("Wir nehmen kurz Kurs auf…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            } else if let plan = model.coursePlan {
                Text(plan)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.indigo.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    @ViewBuilder private var notesBody: some View {
        if model.state.notes.isEmpty {
            Text(model.isLoading ? "recalling…" : "no memory in reach")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.state.notes) { note in
                        noteRow(note)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    /// The one knob the hidden context-builder exposes: how deep it recalls.
    private var recallAdjuster: some View {
        HStack(spacing: 3) {
            depthButton("minus", enabled: model.recallLimit > 1) {
                model.setRecallLimit(model.recallLimit - 1)
            }
            Text("\(model.recallLimit)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 13)
            depthButton("plus", enabled: model.recallLimit < 40) {
                model.setRecallLimit(model.recallLimit + 1)
            }
        }
        .help("Recall depth — how many Mnemosyne notes the assembler conveys")
    }

    private func depthButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1.0 : 0.4)
        .disabled(!enabled)
    }

    private var clearCourseButton: some View {
        Button {
            model.clearConjunction()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Kurs auflösen")
    }

    private func noteRow(_ note: AegisNote) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(note.id)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
            Text(note.content)
                .font(.system(size: 9.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if note.score > 0 {
                Text(String(format: "%.0f", note.score))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Temperature")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Slider(value: $temperature, in: 0.0...2.0, step: 0.1) { editing in
                    if !editing {
                        Task { await model.setTemperature(temperature) }
                    }
                }
                Text(String(format: "%.1f", temperature))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Thinking")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: $thinking) {
                    ForEach(["max", "high", "normal", "fast"], id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: thinking) { _, newValue in
                    Task { await model.setThinking(newValue) }
                }
            }
        }
    }

    private func syncFromModel() {
        if let t = model.state.temperature, abs(t - temperature) > 0.001 {
            temperature = t
        } else if model.state.temperature == nil && temperature != 1.0 {
            temperature = 1.0
        }
        if let s = model.state.thinking, s != thinking {
            thinking = s
        } else if model.state.thinking == nil && thinking != "normal" {
            thinking = "normal"
        }
    }
}

// MARK: - Collapsible chapter

/// One collapsible chapter of the Ægis mirror. The veil teaches the first
/// lesson of any deep surface: it folds. The title band stays; the body
/// withdraws until called.
private struct AegisSection<Content: View>: View {
    let title: String
    var badge: String? = nil
    var accessory: AnyView? = nil
    var initiallyOpen: Bool = true
    @ViewBuilder let content: () -> Content

    @State private var open: Bool? = nil

    private var isOpen: Bool { open ?? initiallyOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        open = !isOpen
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 9)
                        Text(title.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if let accessory { accessory }
            }

            if isOpen {
                content()
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Detached window

/// The Aegis widget lifted out of Pythia into its own small SwiftUI-native
/// floating window — a familiar that follows the editor without stealing focus.
final class AegisWidgetController: NSWindowController, NSWindowDelegate {

    static let shared = AegisWidgetController()

    private var panel: NSWindow?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Aegis"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.contentView = NSHostingView(rootView: DetachedAegisWidgetView(model: .shared))
        window.center()
        self.panel = window
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show or hide the floating panel. `orderOut` (not close) keeps the
    /// controller warm for an instant re-show.
    func toggle() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Detached content

private struct DetachedAegisWidgetView: View {
    @ObservedObject var model: AegisWidgetModel

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.3)
            ScrollView {
                AegisDetailView(model: model)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .onAppear { Task { await model.refresh() } }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.indigo)
            Text("Aegis")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }
            Button {
                AegisWidgetController.shared.toggle()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}