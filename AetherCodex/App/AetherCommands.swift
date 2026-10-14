import SwiftUI
import AppKit

/// The application menu, expressed as SwiftUI commands. This replaces the
/// ~190-line `NSMenu` that `AppDelegate.setupMenu()` assembled by hand.
///
/// Edit-menu conventions (undo/redo/cut/copy/paste/select-all) are left to
/// SwiftUI's standard groups — they route through the responder chain to the
/// `NSTextView`, exactly as before.
struct AetherCommands: Commands {
    let shell: MainWindowController
    let actions: AppActions

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ÆtherCodex") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // ── File ──
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { shell.newTab(nil) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { actions.openDocument() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { shell.openFolder(nil) }
                .keyboardShortcut("O", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { shell.saveDocument(nil) }
                .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Project Settings…") { actions.openProjectSettings() }
            Divider()
            Button("Close Tab") { shell.closeTab(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }

        // ── Edit ──
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Indent") { shell.indentSelection(nil) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { shell.outdentSelection(nil) }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Comment / Uncomment") { shell.toggleComment(nil) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Block Comment") { shell.toggleBlockComment(nil) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            Divider()
            Button("Duplicate Line") { shell.duplicateLine(nil) }
                .keyboardShortcut("d", modifiers: [.control, .shift])
            Button("Move Line Up") { shell.moveLineUp(nil) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Move Line Down") { shell.moveLineDown(nil) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Join Lines") { shell.joinLines(nil) }
                .keyboardShortcut("j", modifiers: .control)
            Button("Select Line") { shell.selectCurrentLine(nil) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Edit Each Line in Selection") { shell.editEachLineInSelection(nil) }
                .keyboardShortcut("w", modifiers: [.control, .shift])
            Button("Select Next Occurrence") { shell.selectNextOccurrence(nil) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Select All Occurrences") { shell.selectAllOccurrences(nil) }
                .keyboardShortcut("g", modifiers: [.command, .control])
            Divider()
            Button("Delete Line") { shell.deleteLine(nil) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Insert Line Below") { shell.insertLineBelow(nil) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Insert Line Above") { shell.insertLineAbove(nil) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button("Uppercase") { shell.uppercaseSelection(nil) }
                .keyboardShortcut("u", modifiers: [.control, .shift])
            Button("Lowercase") { shell.lowercaseSelection(nil) }
                .keyboardShortcut("l", modifiers: [.control, .shift])
            Divider()
            Button("Go to Line…") { shell.goToLine(nil) }
                .keyboardShortcut("l", modifiers: .command)
        }

        appMenus
    }

    /// The five application menus live behind a nested builder. `CommandsBuilder`
    /// composes at most ten children, and `body` already spends six on the
    /// standard File/Edit groups — the eleventh menu dies with a misleading
    /// "extra argument in call" at its own call site.
    @CommandsBuilder
    private var appMenus: some Commands {
        // ── Find ──
        CommandMenu("Find") {
            Button("Find…") { shell.showFindDialog(nil) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find and Replace…") { shell.showFindReplaceDialog(nil) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Use Selection for Find") { shell.useSelectionForFind(nil) }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Find Next") { shell.findReplaceNext(nil) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { shell.findReplacePrevious(nil) }
                .keyboardShortcut("G", modifiers: .command)
            Divider()
            Button("Incremental Search") { shell.toggleQuickSearch(nil) }
                .keyboardShortcut("s", modifiers: .control)
        }

        // ── Navigate ──
        CommandMenu("Navigate") {
            Button("Go to File…") { shell.goToFile(nil) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Search Æther…") { shell.searchAether(nil) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Previous Tab") { shell.previousTab(nil) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { shell.nextTab(nil) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }

        // ── View ──
        CommandMenu("View") {
            Button("Toggle File Browser") { shell.toggleFileBrowser(nil) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Toggle Pythia") { shell.togglePythia(nil) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Oracle Only") { shell.toggleOracleOnly(nil) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Aegis Mirror") { shell.toggleAegis(nil) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Soft Wrap") { shell.toggleWordWrap(nil) }
                .keyboardShortcut("w", modifiers: [.control, .option])
            Button("Line Numbers") { shell.toggleLineNumbers(nil) }
            Button("Wrap Column") { shell.toggleWrapColumn(nil) }
            Menu("Wrap Column Width") {
                ForEach(EditorDisplaySettings.presets, id: \.self) { preset in
                    Button("\(preset)") { EditorDisplaySettings.shared.wrapColumn = preset }
                }
                Divider()
                Button("Other…") { shell.setWrapColumnOther(nil) }
            }
            Button("Highlight Current Line") { shell.toggleHighlightCurrentLine(nil) }
            Button("Show Invisibles") { shell.toggleInvisibles(nil) }
                .keyboardShortcut("i", modifiers: [.control, .option])
            Divider()
            Button("Bigger") { actions.biggerFont() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { actions.smallerFont() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Size") { actions.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        // ── Theme ──
        CommandMenu("Theme") {
            Section("Dark") { themeButtons(for: .dark) }
            Section("Light") { themeButtons(for: .light) }
            Divider()
            Button("Next Theme") { actions.nextTheme() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Theme") { actions.previousTheme() }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            Button("Theme Settings…") { actions.openThemeSettings() }
        }

        // ── Æther ──
        CommandMenu("Æther") {
            Button("Start Ruby Daemon") { actions.startRubyDaemon() }
            Button("Stop Ruby Daemon") { actions.stopRubyDaemon() }
            Divider()
            Button("Test Mnemosyne") { actions.testMnemosyne() }
            Button("Test Aegis") { actions.testAegis() }
            Divider()
            Button("Daemon Status") { actions.daemonStatus() }
            Divider()
            Button("Show Æther Debug") { actions.toggleAetherDebug() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder
    private func themeButtons(for appearance: ThemeAppearance) -> some View {
        let themes = ThemeRegistry.shared.themes
        let active = ThemeRegistry.shared.activeIndex
        ForEach(Array(themes.indices), id: \.self) { index in
            if themes[index].appearance == appearance {
                Button(themes[index].displayName) {
                    actions.selectTheme(index)
                }
                .disabled(false)
                .tag(active == index)
            }
        }
    }
}