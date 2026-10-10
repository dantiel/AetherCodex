import SwiftUI
import Cocoa

// MARK: - Siegel models

/// A plan — Salomo Rex' executive ledger entry. The goal/brief above the task engine.
struct SealSummary: Identifiable {
    let id: Int
    let goal: String
    let description: String
    let status: String
}

/// One milestone of a seal — a real task in the engine, ordered and delegated.
struct SealMilestone: Identifiable {
    let id: Int
    let title: String
    let plan: String
    let status: String
    let owner: String?
    let dependsOn: [Int]
    let order: Int
    let currentStep: Int

    var isDone: Bool { status == "completed" }
    var isFailed: Bool { status == "failed" }
    var isRunning: Bool { status == "active" }
}

struct SealProgress {
    let completed: Int
    let total: Int
    var ratio: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

struct SealExecution: Identifiable {
    var id: Int { taskId }
    let taskId: Int
    let title: String
    let status: String
    let error: String?
}

/// The executive snapshot: seal + ordered milestones + computed next/blocked.
struct SealSnapshot {
    let seal: SealSummary
    let milestones: [SealMilestone]
    let next: SealMilestone?
    let blocked: Bool
    let progress: SealProgress
    let executed: [SealExecution]
}

// MARK: - JSON parsing (snake_case Ruby frames)

private enum SealJSON {
    static func summary(_ d: [String: Any]) -> SealSummary? {
        guard let id = d["id"] as? Int else { return nil }
        return SealSummary(id: id,
                           goal: d["goal"] as? String ?? "",
                           description: d["description"] as? String ?? "",
                           status: d["status"] as? String ?? "active")
    }

    static func milestone(_ d: [String: Any]) -> SealMilestone {
        SealMilestone(id: d["id"] as? Int ?? 0,
                      title: d["title"] as? String ?? "",
                      plan: d["plan"] as? String ?? "",
                      status: d["status"] as? String ?? "pending",
                      owner: d["owner"] as? String,
                      dependsOn: (d["depends_on"] as? [Int]) ?? [],
                      order: d["milestone_order"] as? Int ?? 0,
                      currentStep: d["current_step"] as? Int ?? 0)
    }

    static func snapshot(_ d: [String: Any]) -> SealSnapshot? {
        guard let sealDict = d["seal"] as? [String: Any], let seal = summary(sealDict) else { return nil }
        let milestones = (d["milestones"] as? [[String: Any]] ?? []).map(milestone)
        let next = (d["next"] as? [String: Any]).map(milestone)
        let progressDict = d["progress"] as? [String: Any]
        let progress = SealProgress(completed: progressDict?["completed"] as? Int ?? 0,
                                    total: progressDict?["total"] as? Int ?? 0)
        let executed = (d["executed"] as? [[String: Any]] ?? []).map {
            SealExecution(taskId: $0["id"] as? Int ?? 0,
                          title: $0["title"] as? String ?? "",
                          status: $0["status"] as? String ?? "completed",
                          error: $0["error"] as? String)
        }
        return SealSnapshot(seal: seal, milestones: milestones, next: next,
                            blocked: d["blocked"] as? Bool ?? false,
                            progress: progress, executed: executed)
    }
}

// MARK: - Siegel model (executive view-model)

@MainActor
final class SiegelModel: ObservableObject {
    @Published var seals: [SealSummary] = []
    @Published var snapshot: SealSnapshot?
    @Published var selectedSealId: Int?
    @Published var isLoading = false
    @Published var isRunning = false
    @Published var errorMessage: String?

    private let bridge = RubyBridge.shared

    func refreshSeals() async {
        isLoading = true
        defer { isLoading = false }
        do {
            seals = try await bridge.sealList().compactMap(SealJSON.summary)
            if selectedSealId == nil, let first = seals.first?.id {
                selectedSealId = first
                await refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ id: Int) async {
        selectedSealId = id
        await refresh()
    }

    func refresh() async {
        guard let id = selectedSealId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let dict = try await bridge.sealStatus(id: id) {
                snapshot = SealJSON.snapshot(dict)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Execute the next unblocked milestone (bounded autonomy — one step).
    func runNext() async {
        guard let id = selectedSealId else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            if let dict = try await bridge.sealRun(id: id, maxSteps: 1) {
                snapshot = SealJSON.snapshot(dict)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drive the critical path — execute all remaining unblocked milestones.
    func runAll() async {
        guard let id = selectedSealId else { return }
        let completed = snapshot?.progress.completed ?? 0
        let total = snapshot?.progress.total ?? 0
        let remaining = max(total - completed, 1)
        isRunning = true
        defer { isRunning = false }
        do {
            if let dict = try await bridge.sealRun(id: id, maxSteps: remaining) {
                snapshot = SealJSON.snapshot(dict)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delegate(taskId: Int, owner: String) async {
        do {
            _ = try await bridge.sealDelegate(taskId: taskId, owner: owner)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSeal(goal: String, description: String, milestoneLines: String) async {
        isLoading = true
        defer { isLoading = false }
        var milestones: [[String: Any]] = []
        var idx = 0
        for raw in milestoneLines.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            var m: [String: Any] = ["title": parts[0], "plan": parts[0], "workflow_type": "simple"]
            if parts.count > 1, !parts[1].isEmpty { m["owner"] = parts[1] }
            if idx > 0 { m["depends_on"] = [idx - 1] }
            milestones.append(m)
            idx += 1
        }
        do {
            if let dict = try await bridge.sealCreate(goal: goal,
                                                      description: description.isEmpty ? nil : description,
                                                      milestones: milestones) {
                if let snap = SealJSON.snapshot(dict) {
                    snapshot = snap
                    selectedSealId = snap.seal.id
                }
                await refreshSeals()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Companion glyph resolution

/// Resolve a companion owner id to its glyph + name — correspondence with the
/// roster, not a hardcoded duplicate.
private func companionDisplay(for owner: String?, bridge: RubyBridge) -> (glyph: String, name: String) {
    guard let owner, !owner.isEmpty else { return ("◇", "unvergeben") }
    if let info = bridge.companionRoster.first(where: { $0.key == owner }) {
        return (info.glyph, info.name)
    }
    if let c = pythiaCompanions.first(where: { $0.id == owner }) {
        return (c.glyph, c.displayName)
    }
    return ("👤", owner)
}

// MARK: - Siegel panel (Salomo's temple)

struct SiegelPanel: View {
    /// When set (entity tab), focus the panel on this single seal.
    var initialSealId: Int? = nil
    @StateObject private var model = SiegelModel()
    @ObservedObject private var bridge = RubyBridge.shared
    @Environment(\.pythiaPalette) private var palette
    @State private var showNewSeal = false

    var body: some View {
        VStack(spacing: 0) {
            sealPicker
            Divider().opacity(0.4)
            if let snapshot = model.snapshot {
                sealDetail(snapshot)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.refreshSeals()
            if let id = initialSealId, id != model.selectedSealId {
                await model.select(id)
            }
        }
    }

    // MARK: Seal picker + header

    private var sealPicker: some View {
        HStack(spacing: 6) {
            Text("👑").font(.system(size: 13))
            if model.seals.isEmpty {
                Text("Siegelkabinett")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.foregroundColor)
            } else {
                Picker("Siegel", selection: Binding(
                    get: { model.selectedSealId ?? model.seals.first?.id ?? 0 },
                    set: { id in Task { await model.select(id) } }
                )) {
                    ForEach(model.seals) { seal in
                        Text(seal.goal).tag(seal.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.foregroundColor)
            .help("Aktualisieren")
            Button {
                if let id = model.selectedSealId,
                   let seal = model.seals.first(where: { $0.id == id }) {
                    NotificationCenter.default.post(name: .openEntityInTab,
                                                    object: EntityTabRequest(kind: .seal(id), title: seal.goal))
                }
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.foregroundColor)
            .help("In Tab öffnen")
            Button { showNewSeal = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.foregroundColor)
            .help("Neues Siegel")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .sheet(isPresented: $showNewSeal) {
            NewSealSheet(model: model).environment(\.pythiaPalette, palette)
        }
    }

    // MARK: Detail

    private func sealDetail(_ snapshot: SealSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.seal.goal)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.foregroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if !snapshot.seal.description.isEmpty {
                        Text(snapshot.seal.description)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.foregroundColor.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    progressRow(snapshot)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06), lineWidth: 0.75))

                actionRow(snapshot)

                if snapshot.milestones.isEmpty {
                    Text("Noch keine Meilensteine.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(snapshot.milestones) { m in
                            milestoneRow(m, snapshot: snapshot)
                        }
                    }
                }

                if !snapshot.executed.isEmpty {
                    executionLog(snapshot.executed)
                }
            }
            .padding(10)
        }
    }

    private func progressRow(_ snapshot: SealSnapshot) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: snapshot.progress.ratio)
                .progressViewStyle(.linear)
                .tint(palette.accentColor)
                .frame(maxWidth: .infinity)
            Text("\(snapshot.progress.completed)/\(snapshot.progress.total)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(_ snapshot: SealSnapshot) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.runNext() }
            } label: {
                Label("Nächsten ausführen", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .disabled(model.isRunning || snapshot.next == nil)
            .buttonStyle(.borderedProminent)
            .tint(palette.accentColor)

            Button {
                Task { await model.runAll() }
            } label: {
                Label("Pfad durchlaufen", systemImage: "forward.end.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .disabled(model.isRunning || snapshot.next == nil)
            .buttonStyle(.bordered)

            Spacer(minLength: 0)

            if snapshot.blocked {
                Label("blockiert", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Milestone row

    private func milestoneRow(_ m: SealMilestone, snapshot: SealSnapshot) -> some View {
        let owner = companionDisplay(for: m.owner, bridge: bridge)
        let isNext = snapshot.next?.id == m.id
        let deps = m.dependsOn.compactMap { depId in snapshot.milestones.first { $0.id == depId }?.title }

        return HStack(alignment: .top, spacing: 8) {
            Text("\(m.order)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isNext ? palette.accentColor : .secondary)
                .frame(width: 16, alignment: .trailing)

            Text(owner.glyph)
                .font(.system(size: 14))
                .help(owner.name)

            VStack(alignment: .leading, spacing: 2) {
                Text(m.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.foregroundColor)
                    .strikethrough(m.isDone)
                    .fixedSize(horizontal: false, vertical: true)
                if !deps.isEmpty {
                    Text("← \(deps.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            statusChip(m)
            delegateMenu(m)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(m, isNext: isNext), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            isNext ? palette.accentColor.opacity(0.5) : .white.opacity(0.05), lineWidth: 1))
    }

    private func rowBackground(_ m: SealMilestone, isNext: Bool) -> Color {
        if isNext { return palette.accentColor.opacity(0.12) }
        return Color(nsColor: .quaternaryLabelColor).opacity(0.3)
    }

    private func statusChip(_ m: SealMilestone) -> some View {
        let (text, color) = statusStyle(m)
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func statusStyle(_ m: SealMilestone) -> (String, Color) {
        if m.isFailed { return ("fehlgeschlagen", .red) }
        if m.isDone { return ("vollendet", .green) }
        if m.isRunning { return ("aktiv", palette.accentColor) }
        return ("ausstehend", .secondary)
    }

    private func delegateMenu(_ m: SealMilestone) -> some View {
        Menu {
            ForEach(bridge.companionRoster, id: \.key) { info in
                Button("\(info.glyph) \(info.name)") {
                    Task { await model.delegate(taskId: m.id, owner: info.key) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Delegieren an…")
    }

    private func executionLog(_ executed: [SealExecution]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Jüngste Ausführung")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(executed) { e in
                HStack(spacing: 5) {
                    Image(systemName: e.status == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(e.status == "completed" ? .green : .red)
                    Text(e.title).font(.system(size: 11))
                    if let error = e.error {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("👑").font(.system(size: 30))
            Text("Noch kein Siegel")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foregroundColor)
            Text("Rufe Salomo — »Salomo, plane …« — oder gieße ein Siegel direkt.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Neues Siegel") { showNewSeal = true }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentColor)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New seal sheet

private struct NewSealSheet: View {
    @ObservedObject var model: SiegelModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pythiaPalette) private var palette
    @State private var goal = ""
    @State private var description = ""
    @State private var milestones = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neues Siegel")
                .font(.system(size: 15, weight: .semibold))
            TextField("Ziel", text: $goal)
                .textFieldStyle(.roundedBorder)
            TextField("Beschreibung (optional)", text: $description)
                .textFieldStyle(.roundedBorder)
            Text("Meilensteine — eine pro Zeile: Titel | Begleiter")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextEditor(text: $milestones)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Gießen") {
                    Task {
                        await model.createSeal(goal: goal, description: description, milestoneLines: milestones)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentColor)
                .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}