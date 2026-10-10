import Cocoa
import SwiftUI

// MARK: - Favourite Project

/// A user-registered AetherCodex project — a folder pinned to the favourites
/// view so it can be reopened in one click. Persisted in UserDefaults.
struct FavouriteProject: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let dateAdded: Date

    var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Peer Context

/// A running AetherCodex context discovered over the local ÆtherLink heartbeat
/// scan (ports 4550–4610). Mirrors the shape of `/aether/heartbeat`.
struct PeerContext: Identifiable, Hashable {
    var id: String { path ?? "\(name):\(port)" }
    let name: String
    let path: String?
    let port: Int
    let version: String?
    let capabilities: [String]
    let busy: Bool
    let activeTaskCount: Int
}

// MARK: - ÆtherLink Client

/// Swift-side heartbeat scan — the same discovery loop `AetherLink.discover!`
/// performs in Ruby, reimplemented natively so the favourites view needs no
/// daemon round-trip. Hits `GET /aether/heartbeat` on every candidate port.
struct AetherLinkClient {
    static let scanRange = 4550...4610
    static let heartbeatPath = "/aether/heartbeat"

    static func discover() async -> [PeerContext] {
        await withTaskGroup(of: PeerContext?.self, returning: [PeerContext].self) { group in
            for port in scanRange {
                group.addTask { await heartbeat(port: port) }
            }
            var found: [PeerContext] = []
            for await context in group {
                if let context { found.append(context) }
            }
            return found.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    static func heartbeat(port: Int) async -> PeerContext? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(heartbeatPath)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String, !name.isEmpty else { return nil }
            let tasks = json["active_tasks"] as? [Any] ?? []
            return PeerContext(
                name: name,
                path: json["path"] as? String,
                port: json["port"] as? Int ?? port,
                version: json["version"] as? String,
                capabilities: json["capabilities"] as? [String] ?? [],
                busy: json["busy"] as? Bool ?? false,
                activeTaskCount: tasks.count
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Favourites Store

/// Single source of truth for the favourites list and its live ÆtherLink
/// status. Also computes which discovered peers are not yet favourited.
@MainActor
final class FavouritesStore: ObservableObject {
    static let shared = FavouritesStore()

    @Published var favourites: [FavouriteProject] = []
    @Published var peers: [PeerContext] = []
    @Published var isDiscovering = false

    /// Called when the user opens a favourite project — wired by the window.
    var openProject: ((URL) -> Void)?

    private let defaults = UserDefaults.standard
    private let storageKey = "favourites.projects"

    private init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FavouriteProject].self, from: data)
        else { favourites = []; return }
        favourites = decoded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favourites) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // MARK: Mutation

    /// Resolve a folder's advertised name from its `.aethercodex` `name:` key.
    static func resolveName(for path: String) -> String? {
        let configPath = (path as NSString).appendingPathComponent(".aethercodex")
        guard FileManager.default.fileExists(atPath: configPath) else { return nil }
        let yaml = SimpleYaml.loadFile(configPath)
        if let name = yaml["name"] as? String, !name.isEmpty { return name }
        return nil
    }

    func add(path: String, name: String? = nil) {
        let resolved = name ?? Self.resolveName(for: path) ?? (path as NSString).lastPathComponent
        guard !favourites.contains(where: { $0.path == path }) else { return }
        favourites.append(FavouriteProject(path: path, name: resolved, dateAdded: Date()))
        sortAndSave()
    }

    func remove(_ project: FavouriteProject) {
        favourites.removeAll { $0.path == project.path }
        sortAndSave()
    }

    func toggle(path: String, name: String? = nil) {
        if let index = favourites.firstIndex(where: { $0.path == path }) {
            favourites.remove(at: index)
            save()
        } else {
            add(path: path, name: name)
        }
    }

    func isFavourite(path: String) -> Bool {
        favourites.contains { $0.path == path }
    }

    func addPeer(_ peer: PeerContext) {
        guard let path = peer.path else { return }
        add(path: path, name: peer.name)
    }

    private func sortAndSave() {
        favourites.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        save()
    }

    // MARK: Status

    /// Resolve a favourite's live status by matching its path (or advertised
    /// name) against a discovered peer. Returns `(online, busy, peer)`.
    func status(for project: FavouriteProject) -> (online: Bool, busy: Bool, peer: PeerContext?) {
        if let peer = peers.first(where: { $0.path == project.path || $0.name == project.name }) {
            return (true, peer.busy, peer)
        }
        return (false, false, nil)
    }

    /// Discovered peers whose path is not yet registered as a favourite.
    var undiscoveredPeers: [PeerContext] {
        peers.filter { peer in
            guard let path = peer.path else { return true }
            return !isFavourite(path: path)
        }
    }

    // MARK: Refresh

    func refresh() async {
        isDiscovering = true
        defer { isDiscovering = false }
        peers = await AetherLinkClient.discover()
    }
}

// MARK: - Favourites View

@available(macOS 26.0, *)
struct FavouritesView: View {
    @ObservedObject var store: FavouritesStore
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    favouritesSection
                    if !store.undiscoveredPeers.isEmpty {
                        discoveredSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // Traffic lights + the shared folder row live in the enclosing
                // sidebar safe-area bar; reserve that band.
                Color.clear.frame(height: 46)
                HStack(spacing: 4) {
                    Text("Favourites")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.isDiscovering ? Color.accentColor : .secondary)
                    .help("Refresh discovery")
                    Button {
                        browseAndAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Add a project folder")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider().opacity(0.4)
            }
        }
        .sidebarTabBar(chrome)
        .task { await store.refresh() }
    }

    // MARK: Favourites

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            if store.favourites.isEmpty {
                emptyHint
            } else {
                ForEach(store.favourites) { project in
                    favouriteRow(project)
                }
            }
        }
    }

    private var emptyHint: some View {
        Text("No favourites yet.\nAdd a project folder to pin it here.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func favouriteRow(_ project: FavouriteProject) -> some View {
        let status = store.status(for: project)
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            statusDot(online: status.online, busy: status.busy)
            Button {
                store.remove(project)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Remove from favourites")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
        )
        .onTapGesture { store.openProject?(project.url) }
        .contextMenu {
            Button("Open") { store.openProject?(project.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Divider()
            Button("Remove from Favourites", role: .destructive) { store.remove(project) }
        }
    }

    // MARK: Discovered

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Discovered")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
                .padding(.bottom, 3)
            ForEach(store.undiscoveredPeers) { peer in
                discoveredRow(peer)
            }
        }
    }

    private func discoveredRow(_ peer: PeerContext) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(peer.path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ":\(peer.port)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            statusDot(online: true, busy: peer.busy)
            Button {
                store.addPeer(peer)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add to favourites")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let path = peer.path { store.openProject?(URL(fileURLWithPath: path)) }
        }
    }

    private func statusDot(online: Bool, busy: Bool) -> some View {
        Circle()
            .fill(busy ? Color.orange : (online ? Color.green : Color.gray.opacity(0.6)))
            .frame(width: 7, height: 7)
            .help(busy ? "Busy" : (online ? "Online" : "Offline"))
    }

    // MARK: Actions

    private func browseAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an AetherCodex project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.add(path: url.path)
    }
}

// MARK: - Host View Controller

/// Thin AppKit host so the SwiftUI favourites view can live inside the
/// `SidebarContainer` (which is an AppKit icon-strip + content splitter).
final class FavouritesHostViewController: NSViewController {
    private let store: FavouritesStore
    private let chrome: EditorChromeState

    init(store: FavouritesStore = .shared, chrome: EditorChromeState) {
        self.store = store
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(macOS 26.0, *) {
            let host = NSHostingView(rootView: FavouritesView(store: store, chrome: chrome))
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor, constant: 92),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }
}