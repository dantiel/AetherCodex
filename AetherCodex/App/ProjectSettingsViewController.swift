import Cocoa
import SwiftUI

// MARK: - Project Settings
//
// A separate dialog for the *project* — the `.aethercodex` that governs the
// active context. Only meaningful when a folder is open (project mode); shows an
// empty state otherwise. Options are written surgically into `.aethercodex`
// (comments and unrelated keys preserved), and a one-click link opens the file
// for direct editing. Saving re-activates the daemon context so the new config
// takes effect immediately.

// MARK: - Config model

/// A flat projection of the `.aethercodex` keys the project dialog edits.
/// Values are kept as plain strings; `reasoning-model` may be "yes"/"no" or a
/// concrete reasoning model name, so it stays a text field.
struct ProjectConfig {
    var name = ""
    var apiType = "deepseek"
    var apiUrl = ""
    var model = ""
    var fastModel = ""
    var reasoningModel = "yes"
    var port = ""
    var allowedCommands = "*"

    static let apiTypes = ["deepseek", "openai", "anthropic", "google", "ollama", "custom"]

    /// Keys in the order they should appear when appended to a fresh file.
    private static let keyOrder = [
        "name", "api-type", "api-url", "model",
        "fast-model", "reasoning-model", "port", "allowed-commands",
    ]

    init() {}

    init(text: String) {
        let fields = Self.parse(text)
        name = fields["name"] ?? ""
        apiType = fields["api-type"] ?? "deepseek"
        apiUrl = fields["api-url"] ?? ""
        model = fields["model"] ?? ""
        fastModel = fields["fast-model"] ?? ""
        reasoningModel = fields["reasoning-model"] ?? "yes"
        port = fields["port"] ?? ""
        allowedCommands = fields["allowed-commands"] ?? "*"
    }

    func pairs() -> [(String, String)] {
        [
            ("name", name),
            ("api-type", apiType),
            ("api-url", apiUrl),
            ("model", model),
            ("fast-model", fastModel),
            ("reasoning-model", reasoningModel),
            ("port", port),
            ("allowed-commands", allowedCommands),
        ]
    }

    // MARK: Parse / render

    /// Parse `key: value` lines. Comment lines (`# …`) and inline comments
    /// (`value # note`) are ignored; surrounding quotes are stripped.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Surgically apply `pairs` onto `text`, preserving all other lines and
    /// comments. Existing keys are replaced in place (leading indentation kept);
    /// missing keys are appended.
    static func render(text: String, applying pairs: [(String, String)]) -> String {
        var lines = text.components(separatedBy: "\n")

        // Trim a trailing single empty line so appends land cleanly; we re-join
        // with a final newline below regardless.
        while lines.last?.isEmpty == true { lines.removeLast() }

        for (key, value) in pairs {
            let rendered = "\(key): \(scalar(value))"
            if let idx = lines.firstIndex(where: { lineMatchesKey($0, key) }) {
                let indent = lines[idx].prefix(while: { $0 == " " || $0 == "\t" })
                lines[idx] = String(indent) + rendered
            } else {
                lines.append(rendered)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func lineMatchesKey(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(key + ":") || trimmed == key
    }

    private static func scalar(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "''" }
        if t.contains(" ") || t.contains("#") {
            return "'" + t.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return t
    }
}

// MARK: - Controller

final class ProjectSettingsViewController: NSHostingController<ProjectSettingsView> {
    init() { super.init(rootView: ProjectSettingsView()) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func open() {
        if let window = NSApp.windows.first(where: { $0.contentViewController is ProjectSettingsViewController }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: ProjectSettingsViewController())
        window.title = "Project Settings · AetherCodex"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 600))
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct ProjectSettingsView: View {
    @ObservedObject private var aetherContext = AetherContext.shared
    @State private var config = ProjectConfig()
    @State private var loaded = false
    @State private var status: SaveStatus?

    private enum SaveStatus: Equatable {
        case saved
        case failed(String)
    }

    private var root: String? { aetherContext.root }

    private var configPath: String {
        if let cp = aetherContext.configPath, !cp.isEmpty { return cp }
        return ((root ?? "") as NSString).appendingPathComponent(".aethercodex")
    }

    private var projectName: String {
        aetherContext.name ?? ((root ?? "") as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if root == nil {
                emptyState
            } else {
                content
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: reload)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No project open").font(.title3.weight(.semibold))
            Text("Open a folder to reveal and edit its `.aethercodex` configuration.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(glyph: "gearshape.2", title: projectName, subtitle: configPath)

                Form {
                    Section("Identity") {
                        field("Name", text: $config.name, placeholder: "project name")
                        Picker("Provider", selection: $config.apiType) {
                            ForEach(ProjectConfig.apiTypes, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Models") {
                        field("Model", text: $config.model, placeholder: "deepseek-chat")
                        field("Fast model", text: $config.fastModel, placeholder: "deepseek-flash")
                        field("Reasoning model", text: $config.reasoningModel, placeholder: "yes")
                        Text("`yes` / `no` — or a concrete reasoning model name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Daemon") {
                        field("API URL", text: $config.apiUrl, placeholder: "https://…")
                        field("Port", text: $config.port, placeholder: "4557")
                        field("Allowed commands", text: $config.allowedCommands, placeholder: "*")
                    }
                }
                .formStyle(.grouped)

                actionBar
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                editDirectly()
            } label: {
                Label("Edit `.aethercodex` directly", systemImage: "doc.text")
            }

            Button {
                revealInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Spacer()

            statusBadge

            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    // MARK: Helpers

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            TextField(placeholder.isEmpty ? label : placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func reload() {
        guard root != nil else { return }
        let path = configPath
        if FileManager.default.fileExists(atPath: path),
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            config = ProjectConfig(text: text)
        }
        loaded = true
    }

    private func save() {
        guard let root else { return }
        let path = configPath
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let rendered = ProjectConfig.render(text: existing, applying: config.pairs())
        do {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try rendered.write(toFile: path, atomically: true, encoding: .utf8)
            aetherContext.configPath = path
            status = .saved
            // Re-activate the daemon context so the freshly written config is
            // reloaded immediately (CONFIG.reload! runs on activate_context).
            Task { @MainActor in
                try? await RubyBridge.shared.activateContext(path: root)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func editDirectly() {
        guard root != nil else { return }
        let path = configPath
        if !FileManager.default.fileExists(atPath: path) { save() }
        NotificationCenter.default.post(name: .openFileInEditor, object: URL(fileURLWithPath: path))
    }

    private func revealInFinder() {
        guard root != nil else { return }
        let path = configPath
        if !FileManager.default.fileExists(atPath: path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}