import Cocoa
import SwiftUI

final class ThemeSettingsViewController: NSHostingController<ThemePreferencesView> {
    init() { super.init(rootView: ThemePreferencesView()) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func open() {
        if let window = NSApp.windows.first(where: { $0.contentViewController is ThemeSettingsViewController }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: ThemeSettingsViewController())
        window.title = "Appearance · AetherCodex"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 650))
        window.contentMinSize = NSSize(width: 560, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct ThemePreferencesView: View {
    @State private var revision = 0
    @State private var search = ""
    private let settings = ThemeSettings.shared
    private var theme: SyntaxTheme { ThemeRegistry.shared.current }

    private func binding<T>(_ key: ReferenceWritableKeyPath<ThemeSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0 })
    }

    var body: some View {
        let _ = revision
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color(nsColor: theme.sidebarAccent))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shape your atmosphere").font(.title3.weight(.semibold))
                    Text("Appearance, typography and translucent surfaces").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            TabView {
                themes.tabItem { Label("Themes", systemImage: "paintpalette") }
                typography.tabItem { Label("Typography", systemImage: "textformat") }
                glass.tabItem { Label("Glass", systemImage: "square.stack.3d.up") }
            }.padding(.horizontal, 12)
            HStack {
                Text("Changes apply immediately").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(theme.displayName).font(.caption.weight(.medium)).lineLimit(1)
            }.padding(18)
        }
        .frame(minWidth: 560, minHeight: 540)
        .onReceive(NotificationCenter.default.publisher(for: ThemeSettings.didChangeNotification)) { _ in revision += 1 }
    }

    private var themes: some View {
        Form {
            Section("Theme collection") {
                TextField("Filter by name or tag", text: $search)
                themePicker("Dark appearance", appearance: .dark, key: \.darkThemeName)
                themePicker("Light appearance", appearance: .light, key: \.lightThemeName)
                Text("Follows the system appearance. Each theme supplies its own palette and glass defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Palette") {
                HStack(spacing: 18) {
                    swatch("Editor", theme.editorBackground)
                    swatch("Gutter", theme.rulerBackground)
                    swatch("Sidebar", theme.sidebarBackground ?? theme.rulerBackground)
                    swatch("Accent", theme.sidebarAccent)
                }.padding(.vertical, 8)
            }
            Section("Code preview") {
                Text("func conjure(name: String) {\n    let sigil = \"✦\"\n    // veil parts\n}")
                    .font(Font(settings.resolvedMonoFont))
                    .foregroundStyle(Color(nsColor: theme.editorForeground))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: theme.editorBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }.formStyle(.grouped)
    }

    private func themePicker(_ title: String, appearance: ThemeAppearance,
                             key: ReferenceWritableKeyPath<ThemeSettings, String>) -> some View {
        let matches = ThemeRegistry.shared.themes.filter {
            $0.appearance == appearance && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.name == settings[keyPath: key])
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return Picker(title, selection: Binding(get: { settings[keyPath: key] }, set: {
            settings[keyPath: key] = $0
            ThemeRegistry.shared.activate(named: settings.activeThemeName)
            revision += 1
        })) {
            ForEach(matches, id: \.name) { Text($0.displayName).tag($0.name) }
        }
    }

    private func swatch(_ title: String, _ color: NSColor) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color)).frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.1)))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var typography: some View {
        Form {
            Section("Code · monospaced") {
                Picker("Family", selection: Binding(get: { settings.fontFamily ?? settings.resolvedMonoFont.familyName ?? "Menlo" },
                                                    set: { settings.fontFamily = $0 })) {
                    ForEach(settings.availableMonoFamilies, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: binding(\.fontSize), in: 6...48, step: 1) {
                    Text("Size · \(Int(settings.fontSize)) pt")
                }
            }
            Section("Prose") {
                Picker("Family", selection: Binding(get: { settings.proportionalFontFamily ?? "Helvetica Neue" },
                                                    set: { settings.proportionalFontFamily = $0 })) {
                    ForEach(settings.availableProportionalFamilies, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: binding(\.proportionalFontSize), in: 6...48, step: 1) {
                    Text("Size · \(Int(settings.proportionalFontSize)) pt")
                }
            }
            Section("Reading rhythm") {
                override("Line spacing", key: \.lineSpacingOverride,
                         resolved: Double(settings.resolvedLineSpacing(for: theme)), range: 0...16, unit: "pt")
                override("Text shadow", key: \.textShadowOverride,
                         resolved: Double(settings.resolvedTextShadow(for: theme)))
                Toggle("Highlight current line", isOn: binding(\.highlightCurrentLine))
            }
        }.formStyle(.grouped)
    }

    private var glass: some View {
        Form {
            Section("Window · background behind the app") {
                Text("Native macOS materials, not a continuous blur radius. Lower editor opacity reveals more of the desktop.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Backdrop material", selection: Binding(
                    get: { min(9, max(0, Int(settings.resolvedGlassBlurStrength(for: theme) * 10))) },
                    set: { settings.glassBlurStrengthOverride = (Double($0) + 0.5) / 10 })) {
                    ForEach(Array(["HUD", "Full screen", "Popover", "Menu", "Tooltip", "Under window", "Sidebar", "Sheet", "Window", "Content"].enumerated()), id: \.offset) {
                        Text($0.element).tag($0.offset)
                    }
                }
                Button("Use theme material") { settings.glassBlurStrengthOverride = nil }
                    .font(.caption)
                override("Editor color opacity", key: \.editorBackgroundOpacityOverride,
                         resolved: Double(settings.resolvedEditorBackgroundOpacity(for: theme)))
                override("Glass tint", key: \.glassTintOverride,
                         resolved: Double(settings.resolvedGlassTint(for: theme)))
            }
            Section("Sidebar sheets · content behind the panels") {
                override("Sidebar color opacity", key: \.sidebarBackgroundOpacityOverride,
                         resolved: Double(settings.resolvedSidebarBackgroundOpacity(for: theme)))
                override("Material weight", key: \.sidebarGlassBlurStrengthOverride,
                         resolved: Double(settings.resolvedSidebarGlassBlurStrength(for: theme)))
                Text("Material: \(glassMaterialName(for: settings.resolvedSidebarGlassBlurStrength(for: theme))). Scroll-edge blur remains automatic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("macOS “Reduce transparency” can make native materials opaque. At 100% color opacity, the background is intentionally covered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func override(_ title: String, key: ReferenceWritableKeyPath<ThemeSettings, Double?>,
                          resolved: Double, range: ClosedRange<Double> = 0...1, unit: String = "%") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((unit == "%" ? resolved * 100 : resolved).rounded()))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button(settings[keyPath: key] == nil ? "Theme default" : "Reset") {
                    settings[keyPath: key] = nil
                }.buttonStyle(.borderless).font(.caption)
                    .disabled(settings[keyPath: key] == nil)
            }
            Slider(value: Binding(get: { resolved }, set: { settings[keyPath: key] = $0 }), in: range)
                .accessibilityLabel(title)
        }.padding(.vertical, 4)
    }
}