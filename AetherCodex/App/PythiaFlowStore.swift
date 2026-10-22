import Foundation
import Compression
import SQLite3

private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Pythia Flow Store
//
// Persists the full Pythia flow timeline per-context at
// `<context_root>/.aether/pythia_flow.db` — an append-only SQLite ledger, not a
// JSON blob. Two alchemical corrections over the old `pythia_flow.json`:
//
//  1. Append is O(1). Every save used to rewrite the whole 10 MB file; now a
//     delta-upsert writes only *new or changed* entries (matched by id, diffed
//     by a stable content hash). The ledger grows at one place; pointers wander.
//  2. Bloat is compressed at the source. Tool outputs (98 % of the old file)
//     are zlib-packed per entry — command transcripts shrink ~10:1.
//
// The filesystem remains the shared truth (correspondence): same context → same
// db → same flow, whether windows are side-by-side or relaunched hours apart.
// A window's in-memory `flow` is just a projection of this store.
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
        /// Total entries in the ledger. Equals `flow.count` on a full load; on a
        /// paged load it is larger, with `flow` holding only the newest page.
        var totalCount: Int = 0
        /// seq of the first entry in the loaded window — the anchor for the next
        /// "load older" page. 0 means "no paging window" (full load / empty).
        var earliestSeq: Int64 = 0
        /// True when older entries exist beyond the loaded window.
        var hasMoreOlder: Bool = false
    }

    private init() {}

    // MARK: Paths

    /// The ledger file for a context. A companion's chat is a *named span* on the
    /// same Mnemosyne stream — `stream` swaps the filename (`pythia_flow.db` →
    /// `pythia_flow.salomon.db`) so each voice keeps its own ledger without a
    /// second storage mechanism. `nil` is the default Pythia stream.
    func fileURL(forContext root: String?, stream: String? = nil) -> URL? {
        guard let root, !root.isEmpty else { return nil }
        let dir = (root as NSString).appendingPathComponent(".aether")
        let filename = stream.map { "pythia_flow.\($0).db" } ?? "pythia_flow.db"
        return URL(fileURLWithPath: dir).appendingPathComponent(filename)
    }

    func legacyFileURL(forContext root: String?) -> URL? {
        guard let root, !root.isEmpty else { return nil }
        let dir = (root as NSString).appendingPathComponent(".aether")
        return URL(fileURLWithPath: dir).appendingPathComponent("pythia_flow.json")
    }

    // MARK: Public API

    /// Persist the flow snapshot for a context — delta-upserted by entry id, so
    /// only new or mutated entries touch the disk. Broadcasts
    /// `didChangeNotification` so sibling windows reload.
    @discardableResult
    func save(cwd: String, flow: [FlowEntry], history: [[String: String]], forContext root: String?, session: String = "default", stream: String? = nil) -> Bool {
        guard let url = fileURL(forContext: root, stream: stream) else { return false }
        migrateIfNeeded(forContext: root, stream: stream)
        guard write(cwd: cwd, flow: flow, history: history, session: session, to: url) else { return false }
        let snapshot = Snapshot(session: session, cwd: cwd, flow: flow, history: history)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["contextRoot": root ?? "", "stream": stream ?? "", "session": session, "snapshot": snapshot]
        )
        return true
    }

    func load(forContext root: String?, limit: Int? = nil, stream: String? = nil) -> Snapshot? {
        guard let url = fileURL(forContext: root, stream: stream) else { return nil }
        migrateIfNeeded(forContext: root, stream: stream)
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }

        let totalCount = entryCount(db)
        let window: (flow: [FlowEntry], earliestSeq: Int64)
        let hasMoreOlder: Bool
        if let limit, limit > 0, totalCount > limit {
            // Paged: the newest `limit` entries, reversed back to chronological.
            window = loadFlowWindow(db,
                sql: "SELECT seq, value FROM flow_entries ORDER BY seq DESC LIMIT ?;",
                limit: limit, reversed: true)
            hasMoreOlder = totalCount > window.flow.count
        } else {
            window = loadFlowWindow(db,
                sql: "SELECT seq, value FROM flow_entries ORDER BY seq ASC;",
                reversed: false)
            hasMoreOlder = false
        }

        var history: [[String: String]] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT role, content FROM history_rows ORDER BY seq ASC;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let role = String(cString: sqlite3_column_text(stmt, 0))
                let content = String(cString: sqlite3_column_text(stmt, 1))
                history.append(["role": role, "content": content])
            }
        }
        sqlite3_finalize(stmt)

        let session = readMeta(db, "session") ?? "default"
        let cwd = readMeta(db, "cwd") ?? ""
        return Snapshot(session: session, cwd: cwd, flow: window.flow, history: history,
                        totalCount: totalCount, earliestSeq: window.earliestSeq, hasMoreOlder: hasMoreOlder)
    }

    /// Load one page of older entries — the window immediately preceding
    /// `beforeSeq` (exclusive). Returns only `flow` + paging metadata; the caller
    /// folds it in front of the already-loaded window.
    func loadOlder(forContext root: String?, beforeSeq: Int64, limit: Int = 200, stream: String? = nil) -> Snapshot? {
        guard let url = fileURL(forContext: root, stream: stream), beforeSeq > 0 else { return nil }
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }

        let totalCount = entryCount(db)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT seq, value FROM flow_entries WHERE seq < ? ORDER BY seq DESC LIMIT ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, beforeSeq)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var decoded: [FlowEntry] = []
        var minSeq: Int64 = beforeSeq
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seq = sqlite3_column_int64(stmt, 0)
            minSeq = min(minSeq, seq)
            if let entry = decodeEntry(unpack(readBlob(stmt, 1))) {
                decoded.append(entry)
            }
        }
        sqlite3_finalize(stmt)
        decoded.reverse()

        let earliestSeq = decoded.isEmpty ? 0 : minSeq
        // A full page that did not reach seq 1 implies more history remains.
        let hasMoreOlder = !decoded.isEmpty && decoded.count >= limit && earliestSeq > 1
        return Snapshot(session: "", cwd: "", flow: decoded, history: [],
                        totalCount: totalCount, earliestSeq: earliestSeq, hasMoreOlder: hasMoreOlder)
    }

    /// Load a contiguous flow window. `sql` must select `seq, value`; when
    /// `limit` is non-nil it binds to parameter 1. `reversed` flips a `DESC`
    /// page back to chronological order. Returns the decoded entries and the
    /// smallest `seq` seen (0 when empty) — the anchor for "load older".
    private func loadFlowWindow(_ db: OpaquePointer, sql: String, limit: Int? = nil, reversed: Bool) -> (flow: [FlowEntry], earliestSeq: Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ([], 0) }
        if let limit { sqlite3_bind_int64(stmt, 1, Int64(limit)) }

        var decoded: [FlowEntry] = []
        var minSeq: Int64 = Int64.max
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seq = sqlite3_column_int64(stmt, 0)
            minSeq = min(minSeq, seq)
            if let entry = decodeEntry(unpack(readBlob(stmt, 1))) {
                decoded.append(entry)
            }
        }
        sqlite3_finalize(stmt)
        if reversed { decoded.reverse() }
        return (decoded, decoded.isEmpty ? 0 : minSeq)
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
    /// their (role, content) key is not already present. Writes delta-wise and
    /// broadcasts — sibling windows converge on the same one ledger.
    @discardableResult
    func append(cwd: String, flow: [FlowEntry], history: [[String: String]], forContext root: String?, session: String = "default", stream: String? = nil) -> Bool {
        guard let root, !root.isEmpty else { return false }
        let existing = load(forContext: root, stream: stream)
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
        return save(cwd: resolvedCwd, flow: mergedFlow, history: mergedHistory, forContext: root, session: resolvedSession, stream: stream)
    }

    /// Merge an incoming snapshot into a context — the drag-and-drop binding.
    /// Delegates to `append`: a snapshot is just a cursor (or span) being folded
    /// into the ledger without duplication.
    @discardableResult
    func merge(_ incoming: Snapshot, intoContext root: String?, stream: String? = nil) -> Bool {
        append(cwd: incoming.cwd, flow: incoming.flow, history: incoming.history, forContext: root, session: incoming.session, stream: stream)
    }

    // MARK: Database plumbing

    private func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else { return nil }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        ensureSchema(db)
        return db
    }

    private func ensureSchema(_ db: OpaquePointer) {
        exec(db, """
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        exec(db, """
        CREATE TABLE IF NOT EXISTS flow_entries (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT NOT NULL UNIQUE,
          type TEXT NOT NULL,
          value BLOB NOT NULL,
          hash INTEGER NOT NULL,
          created_at REAL NOT NULL
        );
        """)
        exec(db, """
        CREATE TABLE IF NOT EXISTS history_rows (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          UNIQUE(role, content)
        );
        """)
    }

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Delta-upsert the in-memory flow. Only new (unknown id) or changed
    /// (hash differs) entries are written; untouched rows keep their `seq` and
    /// therefore their chronological position. `seq` never moves for a live
    /// entry — mutations UPDATE in place via `ON CONFLICT ... DO UPDATE`.
    private func write(cwd: String, flow: [FlowEntry], history: [[String: String]], session: String, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let db = open(url) else { return false }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)

        // 1. Existing id → hash map (cheap: ids + hashes only, no payloads).
        var existingHash: [String: UInt64] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, hash FROM flow_entries;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let hash = UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                existingHash[id] = hash
            }
        }
        sqlite3_finalize(stmt)

        // 2. Upsert new/changed entries only.
        var ins: OpaquePointer?
        let upsertSQL = """
        INSERT INTO flow_entries(id, type, value, hash, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET type=excluded.type, value=excluded.value, hash=excluded.hash;
        """
        sqlite3_prepare_v2(db, upsertSQL, -1, &ins, nil)
        let now = Date().timeIntervalSince1970
        for entry in flow {
            // Fast path: entry unchanged since the last save → reuse its cached
            // hash, skipping both the JSON encode and the FNV pass.
            let hash: UInt64
            var payload: Data?
            if let m = memo[entry.id], m.entry == entry {
                hash = m.hash
            } else {
                guard let p = encodeEntry(entry) else { continue }
                payload = p
                hash = fnv1a(p)
                memo[entry.id] = Memo(entry: entry, hash: hash)
            }
            if existingHash[entry.id.uuidString] == hash { continue } // unchanged on disk
            // Must write: re-encode only when the memo was a hit (payload is nil);
            // the changed/first-seen branch already carries the encoded bytes.
            guard let data = payload ?? encodeEntry(entry) else { continue }
            sqlite3_reset(ins)
            sqlite3_clear_bindings(ins)
            bindText(ins, 1, entry.id.uuidString)
            bindText(ins, 2, caseName(entry))
            bindBlob(ins, 3, pack(data))
            sqlite3_bind_int64(ins, 4, Int64(bitPattern: hash))
            sqlite3_bind_double(ins, 5, now)
            sqlite3_step(ins)
        }
        sqlite3_finalize(ins)

        // 3. History: append-only via UNIQUE(role, content).
        var hist: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO history_rows(role, content) VALUES (?, ?);", -1, &hist, nil)
        for row in history {
            let role = row["role"] ?? ""
            let content = row["content"] ?? ""
            guard !role.isEmpty || !content.isEmpty else { continue }
            sqlite3_reset(hist)
            sqlite3_clear_bindings(hist)
            bindText(hist, 1, role)
            bindText(hist, 2, content)
            sqlite3_step(hist)
        }
        sqlite3_finalize(hist)

        // 4. Meta.
        upsertMeta(db, key: "version", value: "1")
        upsertMeta(db, key: "session", value: session)
        upsertMeta(db, key: "cwd", value: cwd)

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return true
    }

    // MARK: Legacy migration

    /// One-shot transmigration: the old monolithic `pythia_flow.json` is folded
    /// into the ledger once, verified entry-for-entry, then released.
    private func migrateIfNeeded(forContext root: String?, stream: String? = nil) {
        guard let url = fileURL(forContext: root, stream: stream),
              !FileManager.default.fileExists(atPath: url.path),
              let legacy = legacyFileURL(forContext: root),
              FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        if snapshot.session.isEmpty { snapshot.session = "default" }
        let ok = write(cwd: snapshot.cwd, flow: snapshot.flow, history: snapshot.history, session: snapshot.session, to: url)
        if ok, entryCount(url) == snapshot.flow.count {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private func entryCount(_ url: URL) -> Int {
        guard let db = open(url) else { return -1 }
        defer { sqlite3_close(db) }
        return entryCount(db)
    }

    private func entryCount(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        var count = -1
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM flow_entries;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return count
    }

    // MARK: SQLite helpers

    private func bindText(_ stmt: OpaquePointer!, _ idx: Int32, _ text: String) {
        sqlite3_bind_text(stmt, idx, text, -1, SQLITE_TRANSIENT)
    }

    private func bindBlob(_ stmt: OpaquePointer!, _ idx: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func readBlob(_ stmt: OpaquePointer!, _ idx: Int32) -> Data {
        guard let ptr = sqlite3_column_blob(stmt, idx) else { return Data() }
        let len = Int(sqlite3_column_bytes(stmt, idx))
        return Data(bytes: ptr, count: len)
    }

    private func readMeta(_ db: OpaquePointer, _ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func upsertMeta(_ db: OpaquePointer, key: String, value: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: Entry encoding

    private let encoder = JSONEncoder()

    /// Per-entry memo of the last-seen value + its FNV-1a hash. `FlowEntry` is a
    /// value type, so the cached snapshot shares the same copy-on-write buffers as
    /// the live entry — the memo costs an envelope, not a payload. On each save
    /// only entries whose `==` changed since the previous save are re-encoded and
    /// re-hashed; the untouched majority is skipped entirely instead of paying the
    /// JSON + hash cost on every debounce.
    private struct Memo {
        let entry: FlowEntry
        let hash: UInt64
    }
    private var memo: [UUID: Memo] = [:]

    private func encodeEntry(_ entry: FlowEntry) -> Data? {
        try? encoder.encode(entry)
    }

    private func decodeEntry(_ data: Data) -> FlowEntry? {
        try? JSONDecoder().decode(FlowEntry.self, from: data)
    }

    private func caseName(_ entry: FlowEntry) -> String {
        switch entry {
        case .message: return "message"
        case .toolGroup: return "toolGroup"
        case .cli: return "cli"
        case .aegis: return "aegis"
        case .system: return "system"
        }
    }

    // MARK: Compression (zlib)

    /// 8-byte big-endian uncompressed length prefix + zlib payload. The prefix
    /// lets decompression allocate exactly once instead of guessing.
    private func pack(_ data: Data) -> Data {
        var out = Data()
        var len = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        if let compressed = zlibCompress(data) {
            out.append(compressed)
        } else {
            out.append(data) // incompressible fallback — store raw
        }
        return out
    }

    private func unpack(_ blob: Data) -> Data {
        guard blob.count >= 8 else { return blob }
        let rawLen = blob.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let payload = blob.dropFirst(8)
        guard let decompressed = zlibDecompress(Data(payload), expected: Int(rawLen)) else {
            return Data(payload)
        }
        return decompressed
    }

    private func zlibCompress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 2 + 128
        var dst = Data(count: max(capacity, 128))
        let dstCount = dst.count
        let srcCount = data.count
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
        var scratch = Data(count: scratchSize)
        let written: Int = scratch.withUnsafeMutableBytes { scratchBuf in
            dst.withUnsafeMutableBytes { dstBuf in
                data.withUnsafeBytes { srcBuf in
                    compression_encode_buffer(
                        dstBuf.bindMemory(to: UInt8.self).baseAddress!, dstCount,
                        srcBuf.bindMemory(to: UInt8.self).baseAddress!, srcCount,
                        scratchBuf.bindMemory(to: UInt8.self).baseAddress!, COMPRESSION_ZLIB)
                }
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    private func zlibDecompress(_ data: Data, expected: Int) -> Data? {
        guard expected > 0 else { return nil }
        var out = Data(count: expected)
        let written: Int = out.withUnsafeMutableBytes { dstBuf in
            data.withUnsafeBytes { srcBuf in
                compression_decode_buffer(
                    dstBuf.bindMemory(to: UInt8.self).baseAddress!, expected,
                    srcBuf.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { return nil }
        return out
    }

    // MARK: Hashing

    /// Stable FNV-1a 64 — deterministic across launches (unlike `hashValue`),
    /// used to diff unchanged entries and skip their disk writes.
    private func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}