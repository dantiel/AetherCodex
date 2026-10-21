import Cocoa
import SwiftUI

extension Notification.Name {
    /// Ask an already-open Project Settings window to reveal its Context tab.
    static let projectSettingsOpenContextTab = Notification.Name("projectSettingsOpenContextTab")
}

// MARK: - Project Settings
//
// A separate dialog for the *project* — the `.aethercodex` that governs the
// active context. Only meaningful when a folder is open (project mode); shows an
// empty state otherwise. Options are written surgically into `.aethercodex`
// (comments and unrelated keys preserved), and a one-click link opens the file
// for direct editing. Saving re-activates the daemon context so the new config
// takes effect immediately.

// MARK: - Config model

/// One annotated related context from the `.aethercodex` `contexts:` section —
/// the ÆtherLink annotation that declares a sibling project (a relation, tagged
/// for routing). `tags` is kept comma-separated for the UI and rendered as a
/// YAML/JSON string array on save.
struct ContextAnnotation: Identifiable, Equatable {
    var id: String { "\(name)|\(port)|\(description)|\(tags)" }
    var name = ""
    var port = ""
    var description = ""
    var tags = ""
}

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
    var contexts: [ContextAnnotation] = []

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
        contexts = Self.parseContexts(text)
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
            if Self.isIndented(raw) { continue }   // `contexts:` block belongs to its own parser
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
            if let idx = lines.firstIndex(where: { !Self.isIndented($0) && lineMatchesKey($0, key) }) {
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

    private static func isIndented(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix("\t")
    }

    // MARK: Contexts (`contexts:` section)

    /// Parse the `.aethercodex` `contexts:` list into editable annotations.
    /// Matches the daemon's canonical form: a YAML list of
    /// `- name: …` entries with optional `port:`, `description:`, `tags: [...]`.
    static func parseContexts(_ text: String) -> [ContextAnnotation] {
        let lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { lineMatchesKey($0, "contexts") }) else { return [] }

        var entries: [ContextAnnotation] = []
        var current = ContextAnnotation()
        var i = idx + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // End of the section: a non-indented, non-comment line.
            if !isIndented(line) {
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    i += 1
                    continue
                }
                break
            }
            if trimmed.hasPrefix("- ") {
                if current.name != "" { entries.append(current) }
                current = ContextAnnotation()
                let body = String(trimmed.dropFirst(2))
                if let colon = body.firstIndex(of: ":") {
                    let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "name" {
                        current.name = stripScalar(String(body[body.index(after: colon)...]))
                    }
                }
            } else if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = stripScalar(String(trimmed[trimmed.index(after: colon)...]))
                switch key {
                case "port":        current.port = value
                case "description": current.description = value
                case "tags":        current.tags = parseTags(value)
                default: break
                }
            }
            i += 1
        }
        if current.name != "" { entries.append(current) }
        return entries
    }

    /// Splice the `contexts:` section back into `text`, replacing an existing
    /// section in place or appending a fresh one — mirroring the daemon's
    /// `CONFIG.write_contexts`. All unrelated lines stay byte-identical.
    static func renderContexts(_ contexts: [ContextAnnotation], into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }

        let body = contextsBody(contexts)
        let idx = lines.firstIndex(where: { lineMatchesKey($0, "contexts") })

        if let idx {
            var finish = idx + 1
            while finish < lines.count && (isIndented(lines[finish]) || lines[finish].trimmingCharacters(in: .whitespaces).isEmpty) {
                finish += 1
            }
            if body.isEmpty {
                lines.removeSubrange(idx..<finish)
            } else {
                lines.replaceSubrange(idx..<finish, with: ["contexts:"] + body)
            }
        } else if !body.isEmpty {
            lines.append("")
            if !lines.contains(where: { $0.contains("RELATED CONTEXTS") }) {
                lines.append("# === RELATED CONTEXTS (AetherLink annotations) ================================")
            }
            lines.append("contexts:")
            lines.append(contentsOf: body)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func contextsBody(_ contexts: [ContextAnnotation]) -> [String] {
        var out: [String] = []
        for c in contexts {
            let name = c.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            out.append("  - name: " + scalar(name))
            let port = c.port.trimmingCharacters(in: .whitespaces)
            if !port.isEmpty, Int(port) != nil {
                out.append("    port: " + port)
            }
            let desc = c.description.trimmingCharacters(in: .whitespaces)
            if !desc.isEmpty {
                out.append("    description: " + scalar(desc))
            }
            let tags = c.tags.trimmingCharacters(in: .whitespaces)
            if !tags.isEmpty {
                out.append("    tags: " + tagsArray(tags))
            }
        }
        return out
    }

    private static func stripScalar(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private static func parseTags(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("[") && v.hasSuffix("]") {
            v = String(v.dropFirst().dropLast())
        }
        let items = v.components(separatedBy: ",").map {
            stripScalar($0)
        }
        return items.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func tagsArray(_ tags: String) -> String {
        let items = tags.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if items.isEmpty { return "[]" }
        return "[" + items.map { "\"" + $0 + "\"" }.joined(separator: ", ") + "]"
    }
}

struct ProjectSettingsView: View {
    enum Tab: Hashable { case general, context }

    @ObservedObject private var aetherContext = AetherContext.shared
    @State private var config = ProjectConfig()
    @State private var loaded = false
    @State private var status: SaveStatus?
    @State private var selectedTab: Tab

    private enum SaveStatus: Equatable {
        case saved
        case failed(String)
    }

    init(initialTab: Tab = .general) {
        _selectedTab = State(initialValue: initialTab)
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
                TabView(selection: $selectedTab) {
                    content
                        .tabItem { Label("General", systemImage: "gearshape.2") }
                        .tag(Tab.general)
                    contextTab
                        .tabItem { Label("Context", systemImage: "network") }
                        .tag(Tab.context)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .projectSettingsOpenContextTab)) { _ in
            selectedTab = .context
        }
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

    // MARK: Context tab (ÆtherLink annotations)

    private var contextTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(glyph: "network", title: "ÆtherLink Context", subtitle: "Declare related contexts (peers) this project relates to. Tags are the relation labels used for routing.")

                // Own identity summary — read-only, mirrors the resolved window context.
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Own context", value: projectName)
                        row("Root", value: root ?? "—")
                        row("Config", value: configPath)
                    }
                    .padding(8)
                }
                .padding(.horizontal, 4)

                if config.contexts.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text("No related contexts declared. Add a sibling project — live peers are discovered on the heartbeat scan (ports 4550–4610).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                }

                ForEach($config.contexts) { $ctx in
                    ContextAnnotationCard(annotation: $ctx, onRemove: {
                        config.contexts.removeAll { $0.id == ctx.id }
                    })
                }

                Button {
                    config.contexts.append(ContextAnnotation(name: "", port: "", description: "", tags: ""))
                } label: {
                    Label("Add related context", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 10)

                actionBar
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
        let flat = ProjectConfig.render(text: existing, applying: config.pairs())
        let rendered = ProjectConfig.renderContexts(config.contexts, into: flat)
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
        FileLinkResolver.open(path)
    }

    private func revealInFinder() {
        guard root != nil else { return }
        let path = configPath
        if !FileManager.default.fileExists(atPath: path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Context annotation card

/// One editable related-context row: name + port + description + tags.
private struct ContextAnnotationCard: View {
    @Binding var annotation: ContextAnnotation
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("name", text: $annotation.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                TextField("port", text: $annotation.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
            HStack {
                Text("desc").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                TextField("description (optional)", text: $annotation.description)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("tags").foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                TextField("comma, separated, relation, labels", text: $annotation.tags)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
        .padding(.vertical, 4)
    }
}