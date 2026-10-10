import Cocoa
import SwiftUI

// MARK: - Settings Dialog
//
// The single settings surface. A sidebar today (New File, Appearance) — more
// sections will join as the app grows. Hermetic chrome: a quiet glass pane,
// not a control panel.

enum SettingsSection: String, CaseIterable, Identifiable {
    case newFile = "New File"
    case editor = "Editor"
    case appearance = "Appearance"
    case git = "Git"

    var id: String { rawValue }
    var glyph: String {
        switch self {
        case .newFile: return "doc.badge.plus"
        case .editor: return "text.cursor"
        case .appearance: return "paintpalette"
        case .git: return "arrow.triangle.branch"
        }
    }
    var subtitle: String {
        switch self {
        case .newFile: return "What a fresh window conjures into being."
        case .editor: return "Text behavior and current-line emphasis."
        case .appearance: return "Themes, typography and translucent glass."
        case .git: return "Diff handoff to your external Git editor."
        }
    }
}

final class SettingsViewController: NSHostingController<SettingsView> {
    init(section: SettingsSection? = nil) {
        super.init(rootView: SettingsView(initialSection: section))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func open(section: SettingsSection? = nil) {
        if let window = NSApp.windows.first(where: { $0.contentViewController is SettingsViewController }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: SettingsViewController(section: section))
        window.title = "Settings · AetherCodex"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 560))
        window.contentMinSize = NSSize(width: 620, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let initialSection: SettingsSection?
    @State private var selection: SettingsSection?

    init(initialSection: SettingsSection? = nil) {
        self.initialSection = initialSection
        _selection = State(initialValue: initialSection ?? .newFile)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.glyph)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            detail(for: selection ?? .newFile)
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(glyph: section.glyph, title: section.rawValue, subtitle: section.subtitle)
                switch section {
                case .newFile: NewFileSettingsView()
                case .editor: EditorSettingsView()
                case .appearance: ThemePreferencesView()
                case .git: GitSettingsView()
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared section header

struct SectionHeader: View {
    let glyph: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }
}

// MARK: - New File section

struct NewFileSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared

    var body: some View {
        Form {
            Section("Content") {
                Picker("New window opens with", selection: $settings.newFileMode) {
                    Text(NewFileMode.blank.label).tag(NewFileMode.blank)
                    Text(NewFileMode.flash.label).tag(NewFileMode.flash)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Language") {
                Picker("Content language", selection: $settings.newFileLanguageMode) {
                    Text(NewFileLanguageMode.plainText.label).tag(NewFileLanguageMode.plainText)
                    Text(NewFileLanguageMode.random.label).tag(NewFileLanguageMode.random)
                    Text(NewFileLanguageMode.specific.label).tag(NewFileLanguageMode.specific)
                }
                .pickerStyle(.radioGroup)

                if settings.newFileLanguageMode == .specific {
                    Picker("Language", selection: $settings.newFileLanguageName) {
                        ForEach(GeneralSettings.knownLanguages, id: \.id) { lang in
                            Text(lang.name).tag(lang.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                summary
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.newFileMode == .flash ? "Flash code poetry" : "Blank document")
                    .font(.body.weight(.medium))
                Text(settings.newFileMode == .flash
                     ? "A fresh hermetic “hello æther” script is conjured by the Oracle when a new window opens."
                     : "A new window opens as an empty document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(languageSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var languageSummary: String {
        switch settings.newFileLanguageMode {
        case .plainText: return "language: plain text"
        case .random: return "language: random (Oracle chooses)"
        case .specific:
            let name = GeneralSettings.knownLanguages.first(where: { $0.id == settings.newFileLanguageName })?.name ?? settings.newFileLanguageName
            return "language: \(name)"
        }
    }
}

// MARK: - Editor section

struct EditorSettingsView: View {
    private let settings = ThemeSettings.shared
    @State private var revision = 0

    private func binding<T>(_ key: ReferenceWritableKeyPath<ThemeSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0 })
    }

    var body: some View {
        let _ = revision
        Form {
            Section("Text") {
                HStack(spacing: 12) {
                    Text("Font size").foregroundStyle(.secondary)
                    Slider(value: binding(\.fontSize), in: 9...24, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                Toggle("Highlight current line", isOn: binding(\.highlightCurrentLine))
            }

            Section("Preview") {
                Text("func conjure(name: String) {\n    let sigil = \"✦ \\(name)\"\n    return sigil\n}")
                    .font(Font(settings.resolvedMonoFont))
                    .foregroundStyle(Color(nsColor: ThemeRegistry.shared.current.editorForeground))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: ThemeRegistry.shared.current.editorBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onReceive(NotificationCenter.default.publisher(for: ThemeSettings.didChangeNotification)) { _ in
            revision += 1
        }
    }
}

// MARK: - Git section

struct GitSettingsView: View {
    @ObservedObject private var settings = GeneralSettings.shared
    @State private var resolved = ""

    var body: some View {
        Form {
            Section("External Diff Editor") {
                HStack(spacing: 12) {
                    Text("Active editor").foregroundStyle(.secondary)
                    Spacer()
                    Text(ExternalEditorResolver.displayName(for: resolved))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Text("Command").foregroundStyle(.secondary)
                    TextField("auto-detect", text: $settings.gitExternalEditor)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Leave empty to auto-detect from `git config core.editor`, then $GIT_EDITOR, $VISUAL, $EDITOR. Examples: `code --wait`, `mate`, `subl -w`, `vim`. Used by the diff view's “open in external editor” button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear { resolved = ExternalEditorResolver.detectedCommand(repoRoot: nil) }
        .onChange(of: settings.gitExternalEditor) { _, _ in
            resolved = ExternalEditorResolver.detectedCommand(repoRoot: nil)
        }
    }
}