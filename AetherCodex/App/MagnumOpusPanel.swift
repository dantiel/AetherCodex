import SwiftUI
import Cocoa

// MARK: - Magnum Opus models

/// One alchemical phase of a task — the unit of the transmutation progress bar.
struct OpusStep: Identifiable {
    let index: Int          // 1-indexed
    let name: String        // workflow-aware phase name (Nigredo, Solve, …)
    let phase: String       // hermetic phase key (nigredo, coagula, …)
    let purpose: String
    let completed: Bool
    let active: Bool
    let rejected: Bool
    let rejectionReason: String?
    let failed: Bool
    let result: String?     // plain text — the model's final narration for this phase
    let toolCallCount: Int
    let toolCalls: [OpusToolCall]  // instrumenta calls the model made during this phase

    var id: Int { index }
}

/// One instrumenta call the model made during a phase — name, arguments and a
/// compact result preview, so the timeline can show *what the model actually did*
/// instead of only a bare count.
struct OpusToolCall: Identifiable {
    let id: String          // stable key "\(stepIndex)-\(callIndex)"
    let name: String
    let args: String
    let result: String
    let executionTime: Double?
    /// False while the instrument is still in flight — the phase shows a live
    /// "running" chip the moment the model starts the call, not only once it
    /// completes. `store_step_tool_calls` (the step-end flush) writes finished
    /// entries without a `done` key, so it defaults to true.
    let done: Bool

    init(id: String, name: String, args: String, result: String, executionTime: Double?, done: Bool = true) {
        self.id = id
        self.name = name
        self.args = args
        self.result = result
        self.executionTime = executionTime
        self.done = done
    }
}

extension OpusToolCall {
    /// Project onto Pythia's `ToolChip` so the phase renders through the same
    /// instrumenta views (`ToolChipRow`) as the chat flow. A compact human line
    /// (verb + filename) is woven in so the collapsed chip reads like Pythia's
    /// "liest Foo.swift", not a bare "read_file read_file".
    var toolChip: ToolChip {
        var chip = ToolChip(name: name, args: args, output: result, done: done)
        chip.message = minifiedLine
        return chip
    }

    private var parsedArgs: [String: Any]? {
        guard let data = args.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private var minifiedLine: String {
        let sem = InstrumentaSemantics.forTool(name)
        if let path = parsedArgs?["path"] as? String, !path.isEmpty {
            return "\(sem.glyph) \(sem.label) \((path as NSString).lastPathComponent)"
        }
        return "\(sem.glyph) \(sem.label)"
    }
}

struct OpusLog: Identifiable {
    let id: Int          // stable index within the append-only log
    let timestamp: Double?
    let message: String
}

struct OpusSubtask: Identifiable {
    let id: Int
    let title: String
    let status: String
}

/// A fully-resolved task snapshot for the detail view.
struct OpusTask: Identifiable {
    let id: Int
    let title: String
    let plan: String
    let status: String
    let workflowType: String
    let currentStep: Int
    let totalSteps: Int
    let steps: [OpusStep]
    let logs: [OpusLog]
    let subtasks: [OpusSubtask]
    let parentTaskId: Int?

    var isActive: Bool { status == "active" }
    var isDone: Bool { status == "completed" }
    var isFailed: Bool { status == "failed" }
}

/// Lightweight row for the task tab strip.
struct OpusTaskSummary: Identifiable {
    let id: Int
    let title: String
    let status: String
    let workflowType: String
    let currentStep: Int
}

// MARK: - JSON parsing (snake_case Ruby frames)

private enum OpusJSON {
    static func summary(_ d: [String: Any]) -> OpusTaskSummary? {
        guard let id = d["id"] as? Int else { return nil }
        return OpusTaskSummary(id: id,
                               title: d["title"] as? String ?? "Task \(id)",
                               status: d["status"] as? String ?? "pending",
                               workflowType: d["workflow_type"] as? String ?? "full",
                               currentStep: d["current_step"] as? Int ?? 0)
    }

    static func step(_ d: [String: Any]) -> OpusStep {
        let index = d["index"] as? Int ?? 0
        let calls = (d["tool_calls"] as? [[String: Any]] ?? []).enumerated().map { idx, c in
            OpusToolCall(id: "\(index)-\(idx)",
                         name: c["name"] as? String ?? "instrument",
                         args: instrumentaStringify(c["args"]),
                         result: instrumentaStringify(c["result"]),
                         executionTime: c["execution_time"] as? Double,
                         done: c["done"] as? Bool ?? true)
        }
        return OpusStep(index: index,
                        name: d["name"] as? String ?? "Step",
                        phase: d["phase"] as? String ?? "",
                        purpose: d["purpose"] as? String ?? "",
                        completed: d["completed"] as? Bool ?? false,
                        active: d["active"] as? Bool ?? false,
                        rejected: d["rejected"] as? Bool ?? false,
                        rejectionReason: d["rejection_reason"] as? String,
                        failed: d["failed"] as? Bool ?? false,
                        result: d["result"] as? String,
                        toolCallCount: d["tool_call_count"] as? Int ?? 0,
                        toolCalls: calls)
    }

    static func task(_ d: [String: Any]) -> OpusTask? {
        guard let id = d["id"] as? Int else { return nil }
        let steps = (d["steps"] as? [[String: Any]] ?? []).map(step)
        let logs = (d["logs"] as? [[String: Any]] ?? []).enumerated().map { idx, entry in
            OpusLog(id: idx,
                    timestamp: entry["timestamp"] as? Double,
                    message: entry["message"] as? String ?? "")
        }
        let subtasks = (d["subtasks"] as? [[String: Any]] ?? []).map {
            OpusSubtask(id: $0["id"] as? Int ?? 0,
                        title: $0["title"] as? String ?? "",
                        status: $0["status"] as? String ?? "pending")
        }
        return OpusTask(id: id,
                        title: d["title"] as? String ?? "Task \(id)",
                        plan: d["plan"] as? String ?? "",
                        status: d["status"] as? String ?? "pending",
                        workflowType: d["workflow_type"] as? String ?? "full",
                        currentStep: d["current_step"] as? Int ?? 0,
                        totalSteps: d["total_steps"] as? Int ?? steps.count,
                        steps: steps,
                        logs: logs,
                        subtasks: subtasks,
                        parentTaskId: d["parent_task_id"] as? Int)
    }
}

// MARK: - Phase color mapping (rainbow transmutation spectrum)

/// The hermetic spectrum — one hue per alchemical step, so the progress bar reads
/// as a true transmutation from Nigredo (blackening) to Rubedo (reddening) and
/// beyond, rather than a monotone meter. Keyed by step index so it stays coherent
/// across workflow types (full/simple/analysis).
private func stepColor(_ index: Int) -> Color {
    let colors: [Color] = [
        Color(red: 0.24, green: 0.24, blue: 0.30), // nigredo (near-black)
        Color(red: 0.86, green: 0.86, blue: 0.90), // albedo (silver)
        Color(red: 0.83, green: 0.69, blue: 0.22), // citrinitas (gold)
        Color(red: 0.75, green: 0.22, blue: 0.20), // rubedo (red)
        Color(red: 0.20, green: 0.53, blue: 0.76), // solve (blue)
        Color(red: 0.42, green: 0.36, blue: 0.91), // coagula (violet)
        Color(red: 0.15, green: 0.68, blue: 0.38), // test (green)
        Color(red: 0.09, green: 0.63, blue: 0.55), // purificatio (teal)
        Color(red: 0.56, green: 0.27, blue: 0.68), // validatio (purple)
        Color(red: 0.83, green: 0.40, blue: 0.16), // documentatio (amber)
    ]
    return colors[(max(index, 1) - 1) % colors.count]
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "active":    return .green
    case "completed": return .blue
    case "failed":    return .red
    case "paused":    return .orange
    case "cancelled": return .gray
    default:          return .secondary.opacity(0.6)
    }
}

// MARK: - Magnum Opus store

@MainActor
final class MagnumOpusStore: ObservableObject {
    @Published var tasks: [OpusTaskSummary] = []
    @Published var selected: OpusTask?
    /// Task IDs currently running (launched this session). Per-task, so several
    /// tasks may run concurrently — unlike the old single `isRunning` gate.
    @Published var runningTaskIds: Set<Int> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let bridge = RubyBridge.shared
    private var pollTask: Task<Void, Never>?
    private var selectedId: Int?
    /// Token for the daemon-stream subscription — task telemetry (`task_*`, `step`)
    /// redraws the panel live instead of only on the 1.4 s poll cadence.
    private var streamToken: UUID?
    /// Debounced refresh scheduled by a burst of stream frames (the engine floods
    /// `task_log_added` per log line); collapses the burst into one redraw.
    private var pendingStreamRefresh: Task<Void, Never>?

    /// Kick off listing + live polling. `list_tasks` and `task_detail` are control
    /// commands — they answer inline on the daemon's reader thread, so this never
    /// queues behind a heavy running task.
    func onAppear() {
        Task { await refreshList() }
        startPolling()
        subscribeStream()
    }

    func onDisappear() {
        pollTask?.cancel()
        pollTask = nil
        pendingStreamRefresh?.cancel()
        pendingStreamRefresh = nil
        if let token = streamToken {
            bridge.removeStreamObserver(token)
            streamToken = nil
        }
    }

    func refreshList() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await bridge.listTasks().compactMap(OpusJSON.summary)
            // Reconcile optimistic "running" ids against the real status: once a
            // task reaches a terminal state it is no longer running, so its
            // launch button unlocks without waiting for another click.
            let terminal = runningTaskIds.filter { id in
                guard let t = tasks.first(where: { $0.id == id }) else { return false }
                return t.status == "completed" || t.status == "failed" || t.status == "cancelled"
            }
            runningTaskIds.subtract(terminal)
            if let sel = selectedId, tasks.contains(where: { $0.id == sel }) {
                await loadDetail(sel)
            } else if selectedId == nil, let first = tasks.first?.id {
                select(first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True when a task is (or was just launched to be) running. The optimistic
    /// `runningTaskIds` covers the instant between the run click and the engine
    /// flipping the task to `active`; the task's own status covers the rest.
    func isRunning(_ id: Int) -> Bool {
        runningTaskIds.contains(id) || (selected?.id == id && selected?.isActive == true)
    }

    func select(_ id: Int) {
        selectedId = id
        Task { await loadDetail(id) }
    }

    func loadDetail(_ id: Int) async {
        do {
            if let dict = try await bridge.taskDetail(id: id) {
                selected = OpusJSON.task(dict)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Launch the task in the background and poll live progress. Runs on the
    /// daemon's worker; the panel never blocks on it — the poller redraws from
    /// the control path. `continueTask` (not `execute_task`) drives every path:
    /// pending tasks start fresh, active/paused/failed tasks resume from their
    /// last clean step — so a stalled phase is re-run, never skipped.
    func run(_ id: Int) {
        launch(id, restart: false)
    }

    /// Re-run the whole workflow from step 0 (keeps the stored history; each
    /// phase overwrites its result as it re-completes). For a failed task this
    /// is the "restart" alternative to continuing from the last clean step.
    func restart(_ id: Int) {
        launch(id, restart: true)
    }

    private func launch(_ id: Int, restart: Bool) {
        runningTaskIds.insert(id)
        startPolling()
        Task { @MainActor in
            do {
                // The daemon answers immediately — the task runs on its own
                // runner thread. `runningTaskIds` keeps the button locked until
                // refreshList sees the terminal status.
                _ = try await bridge.continueTask(id: id, restart: restart)
            } catch {
                errorMessage = error.localizedDescription
                runningTaskIds.remove(id)
            }
            await refreshList()
            await loadDetail(id)
        }
    }

    /// Create a task and refresh the ledger. Returns true on success so the
    /// form can close; on failure the error stays visible *in the form* —
    /// silent confirm failures were the old sheet's death.
    @discardableResult
    func create(title: String, plan: String, workflowType: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            if let dict = try await bridge.createTask(title: title, plan: plan, workflowType: workflowType),
               let id = dict["id"] as? Int {
                select(id)
                await refreshList()
                return true
            }
            errorMessage = "Aufgabe wurde nicht erzeugt (keine ID vom Daemon)."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ id: Int) async {
        do {
            _ = try await bridge.removeTask(id: id)
            if selectedId == id {
                selectedId = nil
                selected = nil
            }
            await refreshList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Subscribe to the daemon's live stream so task telemetry redraws the panel
    /// the instant the engine broadcasts it — not just on the next poll. Filters
    /// to task frames only; the chat panels keep their own `onStream` slot.
    private func subscribeStream() {
        guard streamToken == nil else { return }
        streamToken = bridge.addStreamObserver { [weak self] method, payload in
            guard let self else { return }
            let kind = payload?["type"] as? String ?? ""
            // Engine frames arrive as `method: "status"` (task_started / task_updated /
            // task_completed / task_log_added / …) and `method: "step_result"` (step).
            guard method == "status" || method == "step_result" else { return }
            guard kind.hasPrefix("task_") || kind == "step" else { return }
            Task { @MainActor in
                self.enqueueStreamRefresh()
            }
        }
    }

    /// Debounced redraw: a burst of stream frames collapses into one refresh after
    /// the burst settles. `refreshList` re-fetches the lightweight summary and —
    /// because the completed task no longer vanishes — keeps the selection alive.
    private func enqueueStreamRefresh() {
        pendingStreamRefresh?.cancel()
        pendingStreamRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshList()
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard let self, !Task.isCancelled else { break }
                await self.refreshList()
                let anyActive = self.tasks.contains { $0.status == "active" || $0.status == "pending" }
                if self.runningTaskIds.isEmpty && !anyActive { break }
            }
            self?.pollTask = nil
        }
    }
}

// MARK: - Panel

struct MagnumOpusPanel: View {
    /// When set (entity tab), focus the panel on this single task.
    var initialTaskId: Int? = nil
    @StateObject private var store = MagnumOpusStore()
    @Environment(\.pythiaPalette) private var palette
    @State private var showNewTask = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)

                if store.tasks.isEmpty && store.selected == nil && !store.isLoading {
                    emptyState
                } else {
                    tabStrip
                    Divider().opacity(0.3)
                    if let task = store.selected {
                        OpusTaskDetailView(task: task, store: store)
                    } else {
                        placeholder
                    }
                }

                if let error = store.errorMessage {
                    errorBanner(error)
                }
            }

            if showNewTask {
                NewOpusTaskForm(store: store) {
                    showNewTask = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showNewTask)
        .onAppear {
            if let id = initialTaskId {
                store.select(id)
            }
            store.onAppear()
        }
        .onDisappear { store.onDisappear() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("⚗️")
                .font(.system(size: 13))
            Text("Magnum Opus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.foregroundColor)
            Spacer(minLength: 0)

            Button {
                Task { await store.refreshList() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Aktualisieren")

            Button {
                store.errorMessage = nil
                showNewTask = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Neue Aufgabe")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.tasks) { t in
                    taskTab(t)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func taskTab(_ t: OpusTaskSummary) -> some View {
        let isSelected = store.selected?.id == t.id
        return HStack(spacing: 5) {
            statusDot(t.status)
            Text(t.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                Task { await store.remove(t.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Aufgabe entfernen")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isSelected ? palette.accentColor.opacity(0.22) : Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? palette.accentColor.opacity(0.5) : .white.opacity(0.06), lineWidth: 0.75))
        .contentShape(Capsule())
        .onTapGesture { store.select(t.id) }
        .help("\(t.workflowType) · Schritt \(t.currentStep)")
    }

    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("⚗️")
                .font(.system(size: 34))
            Text("Keine Aufgaben im Tiegel")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.foregroundColor)
            Text("Gieße eine Aufgabe — Salomo orchestriert, das Opus transmutiert.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Neue Aufgabe") {
                store.errorMessage = nil
                showNewTask = true
            }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentColor)
                .font(.system(size: 11, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var placeholder: some View {
        VStack {
            Text("Wähle eine Aufgabe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.10))
    }
}

// MARK: - Single-task editor surface

/// A single Magnum Opus task hosted as a first-class editor tab. Unlike the
/// sidebar panel it has no header, no tab strip, no "new task" chrome — the task
/// *is* the whole content. The sidebar stays the overview; this is the focused
/// transmutation surface. Opening more tasks in the editor remains the sidebar's
/// job (the ⚗️ "in Tab öffnen" button), one tab per task.
struct MagnumOpusTaskView: View {
    let taskId: Int
    @StateObject private var store = MagnumOpusStore()

    var body: some View {
        Group {
            if let task = store.selected, task.id == taskId {
                OpusTaskDetailView(task: task, store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            store.select(taskId)
            store.onAppear()
        }
        .onDisappear { store.onDisappear() }
    }
}

// MARK: - Task detail

private struct OpusTaskDetailView: View {
    let task: OpusTask
    @ObservedObject var store: MagnumOpusStore
    @Environment(\.pythiaPalette) private var palette
    @State private var expandedSteps: Set<Int> = []
    @State private var expandedToolKeys: Set<String> = []
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                taskHeader
                RainbowProgressBar(task: task)
                controls
                Divider().opacity(0.3)
                stepsSection
                if !task.logs.isEmpty {
                    logsSection
                }
            }
            .padding(10)
        }
    }

    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.foregroundColor)
                statusBadge
                Spacer(minLength: 0)
                Text("\(task.currentStep)/\(task.totalSteps)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !task.plan.isEmpty {
                Text(task.plan)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(task.status).opacity(0.18), in: Capsule())
            .foregroundStyle(statusColor(task.status))
    }

    private var statusLabel: String {
        switch task.status {
        case "active": return "aktiv"
        case "completed": return "vollendet"
        case "failed": return "fehlgeschlagen"
        case "pending": return "ausstehend"
        case "paused": return "pausiert"
        case "cancelled": return "abgebrochen"
        default: return task.status
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                store.run(task.id)
            } label: {
                Label(primaryActionLabel, systemImage: primaryActionIcon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accentColor)
            .disabled(store.isRunning(task.id) || task.isDone)

            // A completed task is sealed — no restart. Only a *failed* run
            // (or a paused one) may be re-run from step 1.
            if task.isFailed {
                Button {
                    store.restart(task.id)
                } label: {
                    Label("Neu starten", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .disabled(store.isRunning(task.id))
                .help("Gesamten Workflow ab Schritt 1 neu ausführen")
            }

            Button {
                Task { await store.loadDetail(task.id) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Neu laden")

            Button {
                NotificationCenter.default.post(name: .openEntityInTab,
                                                object: EntityTabRequest(kind: .opusTask(task.id), title: task.title))
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("In Tab öffnen")

            Spacer(minLength: 0)

            Button {
                Task { await store.remove(task.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("Aufgabe entfernen")
        }
    }

    /// Primary button label — resume semantics differ from a fresh run. A task
    /// stuck in `active` (daemon died mid-phase) or `failed`/`paused` is resumed
    /// from its last clean step, not re-run from scratch.
    private var primaryActionLabel: String {
        switch task.status {
        case "active", "failed", "paused": return "Fortsetzen"
        case "completed": return "Vollendet"
        default: return "Ausführen"
        }
    }

    private var primaryActionIcon: String {
        task.isFailed ? "arrow.uturn.backward.circle.fill" : "play.fill"
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transmutation")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 4) {
                ForEach(task.steps) { step in
                    stepRow(step)
                }
            }
        }
    }

    private func stepRow(_ step: OpusStep) -> some View {
        let isExpanded = expandedSteps.contains(step.index)
        let isLast = step.index == task.totalSteps
        return HStack(alignment: .top, spacing: 8) {
            timelineRail(step, isLast: isLast)

            VStack(alignment: .leading, spacing: 0) {
                phaseHeader(step, isExpanded: isExpanded)
                if isExpanded {
                    phaseDetail(step)
                }
            }
        }
    }

    /// The git-log style rail — a colored node per phase with a vertical line
    /// connecting it to the next, so the timeline reads as one transmutation
    /// rather than a stack of disconnected rows.
    private func timelineRail(_ step: OpusStep, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            stepGlyph(step)
                .font(.system(size: 12))
                .shadow(color: step.active ? stepColor(step.index).opacity(0.8) : .clear, radius: 3)
            if !isLast {
                Rectangle()
                    .fill(railColor(step))
                    .frame(width: step.active ? 3 : 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 16)
        .padding(.top, 5)
    }

    /// The rail segment below a step carries that step's hue — completed phases
    /// fade, but the *current* (active) phase keeps its full step color so the
    /// timeline visually belongs to the step being transmuted right now.
    private func railColor(_ step: OpusStep) -> Color {
        if step.active { return stepColor(step.index) }
        if step.completed { return stepColor(step.index).opacity(0.30) }
        return Color.white.opacity(0.07)
    }

    /// The whole header is the expand/collapse target — no more hunting for the
    /// tiny chevron. The active phase carries its own alchemical hue (the same
    /// color as its timeline rail + glyph), so the transmutation reads as one
    /// coherent stroke from node to rail to header.
    private func phaseHeader(_ step: OpusStep, isExpanded: Bool) -> some View {
        let color = stepColor(step.index)
        return HStack(spacing: 7) {
            if step.active {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3)
            }
            Text(step.name)
                .font(.system(size: 11, weight: step.active ? .semibold : .regular))
                .foregroundStyle(step.active ? color : palette.foregroundColor.opacity(0.8))
            if step.toolCallCount > 0 {
                Text("\(step.toolCallCount) ⚒")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(step.active ? color.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(step.active ? color.opacity(0.9) : .secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(step.active ? color.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(step.active ? color.opacity(0.6) : .white.opacity(0.05),
                              lineWidth: step.active ? 1 : 0.75)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                if isExpanded { expandedSteps.remove(step.index) }
                else { expandedSteps.insert(step.index) }
            }
        }
    }

    /// The expanded phase body: a one-line overview first, then the instrumenta
    /// calls and the model's final narration — each collapsed until the user
    /// unfolds them, so a phase never dumps its whole working history at once.
    private func phaseDetail(_ step: OpusStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // PHASE OVERVIEW — the summary the user sees first.
            HStack(spacing: 5) {
                stepGlyph(step).font(.system(size: 9))
                Text(step.purpose)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.foregroundColor.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(palette.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            if let reason = step.rejectionReason {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            // INSTRUMENTA CALLS — collapsed cluster, unfold per call for its result.
            if !step.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instrumenta")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(step.toolCalls) { call in
                        toolCallRow(step, call)
                    }
                }
            }

            // MODEL THOUGHTS — the phase's final narration, collapsed by default.
            if let result = step.result, !result.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erkenntnis")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(result)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.codeForegroundColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(palette.codeBackgroundColor.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.top, 5)
        .padding(.bottom, 7)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// One instrumenta call inside a phase — rendered through Pythia's *real*
    /// instrumenta views (`ToolChipRow`): companion gestures speak, file reads/
    /// patches/creates get their dedicated cards, the shell shows its CLI block.
    /// Collapsed it is the minified semantic line; unfolded it becomes the same
    /// card the chat flow draws. No more bare monospaced tool name.
    private func toolCallRow(_ step: OpusStep, _ call: OpusToolCall) -> some View {
        let key = call.id
        let isOpen = expandedToolKeys.contains(key)
        return ToolChipRow(
            chip: call.toolChip,
            level: .compact,
            isExpanded: isOpen,
            onToggle: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if isOpen { expandedToolKeys.remove(key) }
                    else { expandedToolKeys.insert(key) }
                }
            }
        )
        .padding(.leading, 2)
    }

    private func stepGlyph(_ step: OpusStep) -> some View {
        Group {
            if step.rejected {
                Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange)
            } else if step.failed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else if step.active {
                Image(systemName: "circle.fill").foregroundStyle(stepColor(step.index))
            } else if step.completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(stepColor(step.index))
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11))
        .help(step.purpose)
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { showLogs.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showLogs ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Ausführungs-Log")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showLogs {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(task.logs.suffix(30)) { log in
                        Text(log.message)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Rainbow transmutation progress bar

/// A segmented bar — one segment per alchemical phase, filled across the
/// spectrum as the opus progresses. The "topmost rainbow transmutation" the old
/// plugin reached for, now a true per-step gauge.
private struct RainbowProgressBar: View {
    let task: OpusTask

    var body: some View {
        HStack(spacing: 2) {
            ForEach(task.steps) { step in
                segment(step)
            }
        }
        .frame(height: 10)
    }

    private func segment(_ step: OpusStep) -> some View {
        let color = stepColor(step.index)
        return RoundedRectangle(cornerRadius: 2)
            .fill(fill(step, color: color))
            .overlay(
                step.active
                    ? RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.6), lineWidth: 0.75)
                    : nil
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step.completed)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step.active)
            .help(stepHelp(step))
    }

    private func fill(_ step: OpusStep, color: Color) -> Color {
        if step.rejected || step.failed { return .red.opacity(0.85) }
        if step.active { return color.opacity(0.95) }
        if step.completed { return color }
        return color.opacity(0.16)
    }

    private func stepHelp(_ step: OpusStep) -> String {
        var s = "\(step.name) — \(step.purpose)"
        if step.rejected { s += " (abgelehnt)" }
        if step.failed { s += " (fehlgeschlagen)" }
        if step.active { s += " (aktiv)" }
        return s
    }
}

// MARK: - New task form (in-panel — no sheet)

/// The task-forging form renders INSIDE the panel, not as a separate sheet
/// window. A `.sheet` presented from a view nested in the editor's NSHostingView
/// chain never became key — clicks on its confirm died silently. An in-panel
/// overlay stays in the same window and responder chain as everything else.
private struct NewOpusTaskForm: View {
    @ObservedObject var store: MagnumOpusStore
    let onCancel: () -> Void
    @Environment(\.pythiaPalette) private var palette
    @State private var title = ""
    @State private var plan = ""
    @State private var workflowType = "full"
    @State private var creating = false

    private let workflows = [
        ("full", "Voll (10 Phasen)"),
        ("simple", "Simpel (3 Phasen)"),
        ("analysis", "Analyse (5 Phasen)"),
    ]

    private var canPour: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !creating { onCancel() } }

            VStack(alignment: .leading, spacing: 12) {
                Text("Neue Aufgabe gießen")
                    .font(.system(size: 14, weight: .semibold))

                TextField("Titel", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(creating)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workflow")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $workflowType) {
                        ForEach(workflows, id: \.0) { wf in
                            Text(wf.1).tag(wf.0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(creating)
                }

                Text("Plan (Markdown)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $plan)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(creating)

                if let error = store.errorMessage, !error.isEmpty {
                    Text("⚠️ \(error)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Abbrechen") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(creating)
                    Button {
                        creating = true
                        Task {
                            let ok = await store.create(title: title, plan: plan,
                                                        workflowType: workflowType)
                            creating = false
                            if ok { onCancel() }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if creating {
                                ProgressView().controlSize(.small)
                            }
                            Text("Gießen")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPour)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accentColor)
                }
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(16)
        }
    }
}