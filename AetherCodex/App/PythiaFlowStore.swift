import Foundation

// MARK: - Pythia Flow Store

/// Persists the full Pythia flow timeline per-context at
/// `<context_root>/.aether/pythia_flow.json`, and broadcasts every save so
/// multiple windows of the *same* context converge on one timeline.
///
/// The filesystem is the shared truth (correspondence): same context → same
/// file → same flow, whether the windows are side-by-side or relaunched hours
/// apart. A window's in-memory `flow` is just a projection of this store.
final class PythiaFlowStore {
    static let shared = PythiaFlowStore()

    /// Posted synchronously after every successful save. `userInfo` carries
    /// `"contextRoot"` (String) and `"snapshot"` (Snapshot).
    static let didChangeNotification = Notification.Name("PythiaFlowStore.didChange")

    struct Snapshot: Codable {
        var version: Int = 1
        /// Named thread this snapshot belongs to. A window session is a
        /// *span* on the one ledger — `session` is its name, not a container.
        var session: String
        var cwd: String
        var flow: [FlowEntry]
        var history: [[String: String]]
    }

    private init() {}

    func fileURL(forContext root: String?) -> URL? {
        guard let root, !root.isEmpty else { return nil }
        let dir = (root as NSString).appendingPathComponent(".aether")
        return URL(fileURLWithPath: dir).appendingPathComponent("pythia_flow.json")
    }

    /// Write the flow snapshot for a context. Returns `true` on success and
    /// broadcasts `didChangeNotification` so sibling windows reload.
    @discardableResult
    func save(cwd: String, flow: [FlowEntry], history: [[String: String]], forContext root: String?, session: String = "default") -> Bool {
        guard let url = fileURL(forContext: root) else { return false }
        let snapshot = Snapshot(session: session, cwd: cwd, flow: flow, history: history)
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["contextRoot": root ?? "", "snapshot": snapshot]
        )
        return true
    }

    func load(forContext root: String?) -> Snapshot? {
        guard let url = fileURL(forContext: root) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        // Backward compatibility: snapshots written before the session field
        // decode with an empty session; normalise to "default" on read.
        if snapshot?.session.isEmpty ?? false { snapshot?.session = "default" }
        return snapshot
    }

    /// Merge an incoming flow into a context's ledger — append-only, deduplicated
    /// by entry id. This is the drag-and-drop binding: a cursor (or a whole span)
    /// is folded into the target span without duplicating anything. Returns the
    /// merged flow without persisting (the caller decides when to write).
    func merge(_ incoming: [FlowEntry], into existing: [FlowEntry]) -> [FlowEntry] {
        let seen = Set(existing.map(\.id))
        return existing + incoming.filter { !seen.contains($0.id) }
    }

    /// Append a completed turn's new entries to the ledger — the append-only
    /// primitive (Invariant 1, "Soldaten-Energie"). New flow entries are folded
    /// in only if their `id` is not already present; new history rows only if
    /// their (role, content) key is not already present. Writes atomically and
    /// broadcasts — sibling windows converge on the same one ledger. This is
    /// *append*, never *overwrite*: the ledger grows at one place, pointers wander.
    @discardableResult
    func append(cwd: String, flow: [FlowEntry], history: [[String: String]], forContext root: String?, session: String = "default") -> Bool {
        guard let root, !root.isEmpty else { return false }
        let existing = load(forContext: root)
        let mergedFlow = existing.map { merge(flow, into: $0.flow) } ?? flow

        func historyKey(_ row: [String: String]) -> String {
            "\(row["role"] ?? "")\u{0}\(row["content"] ?? "")"
        }
        var seenHistory = Set<String>()
        var mergedHistory = existing?.history ?? []
        for row in mergedHistory { seenHistory.insert(historyKey(row)) }
        for row in history {
            let key = historyKey(row)
            guard key != "\u{0}", !seenHistory.contains(key) else { continue }
            seenHistory.insert(key)
            mergedHistory.append(row)
        }

        let resolvedSession = session.isEmpty ? (existing?.session ?? "default") : session
        let resolvedCwd = cwd.isEmpty ? (existing?.cwd ?? "") : cwd
        return save(cwd: resolvedCwd, flow: mergedFlow, history: mergedHistory, forContext: root, session: resolvedSession)
    }

    /// Merge an incoming snapshot into a context — the drag-and-drop binding.
    /// Delegates to `append`: a snapshot is just a cursor (or span) being folded
    /// into the ledger without duplication.
    @discardableResult
    func merge(_ incoming: Snapshot, intoContext root: String?) -> Bool {
        append(cwd: incoming.cwd, flow: incoming.flow, history: incoming.history, forContext: root, session: incoming.session)
    }
}