import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        FontBundler.registerAll()
        RubyBridge.shared.initialize()
        mainWindowController = MainWindowController()
        restoreSession()
        // Capture the intended frame before the SwiftUI hosting view collapses the
        // window to its content's ideal size during the first layout pass.
        let intendedFrame = mainWindowController?.window?.frame
        mainWindowController?.showWindow(self)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        // Re-assert the intended frame after layout settles. Reading the saved
        // frame here would be wrong — the collapse already re-saved the collapsed
        // size — so we use the value captured above.
        let reassertFrame = { [weak self] in
            guard let self, let window = self.mainWindowController?.window,
                  let frame = intendedFrame else { return }
            window.setFrame(frame, display: true, animate: false)
        }
        // The SwiftUI hosting view collapses the window to its content's ideal
        // size (the document height) during its first layout pass, at a
        // non-deterministic moment. Re-assert the intended frame several times
        // so one of them lands after the collapse and sticks.
        for delay in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reassertFrame)
        }
        setupMenu()
        NSApp.activate(ignoringOtherApps: true)
        
        // Open files passed on command line
        let args = CommandLine.arguments.dropFirst() // drop executable path
        for arg in args {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: arg) {
                mainWindowController?.openFileInTab(url)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        RubyBridge.shared.cleanup()
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if FileManager.default.fileExists(atPath: filename) {
            mainWindowController?.openFileInTab(url)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }
    
    // MARK: - Session Persistence
    
    private func restoreSession() {
        let s = SessionState.shared
        guard let mwc = mainWindowController else { return }
        
        // Force-load window so it exists for frame/file restore
        _ = mwc.window
        guard let window = mwc.window else { return }
        
        // Restore window frame
        if let frame = s.windowFrame {
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            window.setFrame(rect, display: true)
        }
        
        // Restore open files FIRST (before folder, so the editor is ready). The
        // first file fills the initial untitled tab; the rest open as new tabs.
        let openPaths = s.openTabs.isEmpty ? (s.lastOpenFile.map { [$0] } ?? []) : s.openTabs
        for path in openPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                mwc.openFileInTab(url)
            }
        }
        
        // Restore project folder
        if let path = s.lastProjectFolder {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                mwc.fileBrowser?.openFolder(url)
            }
        }
        
        // Restore sidebar width if stored
        if let w = s.sidebarWidth {
            mwc.restoreSidebarWidth(CGFloat(w))
        }
        if let w = s.pythiaWidth {
            mwc.restorePythiaWidth(CGFloat(w))
        }

        // Restore overlay mode
        if s.fileBrowserOverlay {
            ThemeSettings.shared.fileBrowserOverlay = true
            mwc.syncOverlayMode()
        }

        // Restore active theme
        if let themeName = s.activeThemeName,
           let index = ThemeRegistry.shared.themes.firstIndex(where: { $0.name == themeName }) {
            ThemeRegistry.shared.activate(index: index)
        }
    }
    
    // Window lifecycle — called by MainWindowController when closing
    func windowControllerWillClose(_ controller: MainWindowController) {
        saveSession()
        if mainWindowController === controller {
            mainWindowController = nil
        }
    }
    
    // MARK: - Menu Actions
    
    @objc func newDocument(_ sender: Any?) {
        let mwc = MainWindowController()
        mainWindowController = mwc
        mwc.showWindow(nil)
        mwc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let mwc = self.mainWindowController ?? {
                let wc = MainWindowController()
                self.mainWindowController = wc
                wc.showWindow(nil)
                return wc
            }()
            mwc.openFileInTab(url)
        }
    }
    
    private func saveSession() {
        guard let mwc = mainWindowController else { return }
        mwc.saveSessionState()
        SessionState.shared.flush()  // no-op kept for API compatibility; UserDefaults syncs automatically
    }
    
    private func setupMenu() {
        let mainMenu = NSMenu()
        
        // ── App ──
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu(title: "AetherCodex")
        appMenuItem.submenu?.addItem(withTitle: "About", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenuItem.submenu?.addItem(NSMenuItem.separator())
        appMenuItem.submenu?.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        appMenuItem.submenu?.addItem(NSMenuItem.separator())
        appMenuItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)
        
        // ── File ──
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = NSMenu(title: "File")
        fileMenuItem.submenu?.addItem(withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        let newTabItem = fileMenuItem.submenu?.addItem(withTitle: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "n")
        newTabItem?.keyEquivalentModifierMask = [.command, .shift]
        fileMenuItem.submenu?.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenuItem.submenu?.addItem(withTitle: "Open Folder…", action: #selector(MainWindowController.openFolder(_:)), keyEquivalent: "O")
        fileMenuItem.submenu?.addItem(NSMenuItem.separator())
        fileMenuItem.submenu?.addItem(withTitle: "Project Settings…", action: #selector(AppDelegate.openProjectSettings(_:)), keyEquivalent: "")
        fileMenuItem.submenu?.addItem(withTitle: "Save", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        fileMenuItem.submenu?.addItem(NSMenuItem.separator())
        fileMenuItem.submenu?.addItem(withTitle: "Close Tab", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        mainMenu.addItem(fileMenuItem)

        // ── Edit ──
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = NSMenu(title: "Edit")
        editMenuItem.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenuItem.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        editMenuItem.submenu?.addItem(withTitle: "Cut", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x")
        editMenuItem.submenu?.addItem(withTitle: "Copy", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")
        editMenuItem.submenu?.addItem(withTitle: "Paste", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v")
        editMenuItem.submenu?.addItem(withTitle: "Delete", action: #selector(NSTextView.delete(_:)), keyEquivalent: "\u{8}")
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        editMenuItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        editMenuItem.submenu?.addItem(withTitle: "Indent", action: #selector(MainWindowController.indentSelection(_:)), keyEquivalent: "]")
        editMenuItem.submenu?.addItem(withTitle: "Outdent", action: #selector(MainWindowController.outdentSelection(_:)), keyEquivalent: "[")
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        editMenuItem.submenu?.addItem(withTitle: "Comment / Uncomment", action: #selector(MainWindowController.toggleComment(_:)), keyEquivalent: "/")
        let blockCommentItem = editMenuItem.submenu?.addItem(withTitle: "Block Comment", action: #selector(MainWindowController.toggleBlockComment(_:)), keyEquivalent: "/")
        blockCommentItem?.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        let duplicateItem = editMenuItem.submenu?.addItem(withTitle: "Duplicate Line", action: #selector(MainWindowController.duplicateLine(_:)), keyEquivalent: "d")
        duplicateItem?.keyEquivalentModifierMask = [.control, .shift]
        let moveUpItem = editMenuItem.submenu?.addItem(withTitle: "Move Line Up", action: #selector(MainWindowController.moveLineUp(_:)), keyEquivalent: "\u{F700}")
        moveUpItem?.keyEquivalentModifierMask = [.command, .control]
        let moveDownItem = editMenuItem.submenu?.addItem(withTitle: "Move Line Down", action: #selector(MainWindowController.moveLineDown(_:)), keyEquivalent: "\u{F701}")
        moveDownItem?.keyEquivalentModifierMask = [.command, .control]
        let joinItem = editMenuItem.submenu?.addItem(withTitle: "Join Lines", action: #selector(MainWindowController.joinLines(_:)), keyEquivalent: "j")
        joinItem?.keyEquivalentModifierMask = [.control]
        let selectLineItem = editMenuItem.submenu?.addItem(withTitle: "Select Line", action: #selector(MainWindowController.selectCurrentLine(_:)), keyEquivalent: "l")
        selectLineItem?.keyEquivalentModifierMask = [.command, .shift]
        let editEachLineItem = editMenuItem.submenu?.addItem(withTitle: "Edit Each Line in Selection", action: #selector(MainWindowController.editEachLineInSelection(_:)), keyEquivalent: "w")
        editEachLineItem?.keyEquivalentModifierMask = [.control, .shift]
        let selectNextOccurrenceItem = editMenuItem.submenu?.addItem(withTitle: "Select Next Occurrence", action: #selector(MainWindowController.selectNextOccurrence(_:)), keyEquivalent: "d")
        selectNextOccurrenceItem?.keyEquivalentModifierMask = [.command]
        let selectAllOccurrencesItem = editMenuItem.submenu?.addItem(withTitle: "Select All Occurrences", action: #selector(MainWindowController.selectAllOccurrences(_:)), keyEquivalent: "g")
        selectAllOccurrencesItem?.keyEquivalentModifierMask = [.command, .control]
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        let deleteLineItem = editMenuItem.submenu?.addItem(withTitle: "Delete Line", action: #selector(MainWindowController.deleteLine(_:)), keyEquivalent: "k")
        deleteLineItem?.keyEquivalentModifierMask = [.command, .shift]
        let insertBelowItem = editMenuItem.submenu?.addItem(withTitle: "Insert Line Below", action: #selector(MainWindowController.insertLineBelow(_:)), keyEquivalent: "\r")
        insertBelowItem?.keyEquivalentModifierMask = [.command]
        let insertAboveItem = editMenuItem.submenu?.addItem(withTitle: "Insert Line Above", action: #selector(MainWindowController.insertLineAbove(_:)), keyEquivalent: "\r")
        insertAboveItem?.keyEquivalentModifierMask = [.command, .shift]
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        let uppercaseItem = editMenuItem.submenu?.addItem(withTitle: "Uppercase", action: #selector(MainWindowController.uppercaseSelection(_:)), keyEquivalent: "u")
        uppercaseItem?.keyEquivalentModifierMask = [.control, .shift]
        let lowercaseItem = editMenuItem.submenu?.addItem(withTitle: "Lowercase", action: #selector(MainWindowController.lowercaseSelection(_:)), keyEquivalent: "l")
        lowercaseItem?.keyEquivalentModifierMask = [.control, .shift]
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        editMenuItem.submenu?.addItem(withTitle: "Go to Line…", action: #selector(MainWindowController.goToLine(_:)), keyEquivalent: "l")
        editMenuItem.submenu?.addItem(NSMenuItem.separator())
        // Find submenu (TextMate-style: ⌘F dialog, ⌘G/⇧⌘G navigate, ⌘E capture)
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find…", action: #selector(MainWindowController.showFindDialog(_:)), keyEquivalent: "f")
        let findReplaceMenuItem = findMenu.addItem(withTitle: "Find and Replace…", action: #selector(MainWindowController.showFindReplaceDialog(_:)), keyEquivalent: "f")
        findReplaceMenuItem.keyEquivalentModifierMask = [.command, .option]
        findMenu.addItem(withTitle: "Use Selection for Find", action: #selector(MainWindowController.useSelectionForFind(_:)), keyEquivalent: "e")
        findMenu.addItem(NSMenuItem.separator())
        findMenu.addItem(withTitle: "Find Next", action: #selector(MainWindowController.findReplaceNext(_:)), keyEquivalent: "g")
        findMenu.addItem(withTitle: "Find Previous", action: #selector(MainWindowController.findReplacePrevious(_:)), keyEquivalent: "G")
        findMenu.addItem(NSMenuItem.separator())
        findMenu.addItem(withTitle: "Incremental Search", action: #selector(MainWindowController.toggleQuickSearch(_:)), keyEquivalent: "s")
        findMenu.item(at: 7)?.keyEquivalentModifierMask = .control
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu
        editMenuItem.submenu?.addItem(findItem)
        mainMenu.addItem(editMenuItem)

        // ── Navigate ──
        let navigateMenuItem = NSMenuItem()
        navigateMenuItem.submenu = NSMenu(title: "Navigate")
        navigateMenuItem.submenu?.addItem(withTitle: "Go to File…", action: #selector(MainWindowController.goToFile(_:)), keyEquivalent: "t")
        let searchAetherItem = navigateMenuItem.submenu?.addItem(withTitle: "Search Æther…", action: #selector(MainWindowController.searchAether(_:)), keyEquivalent: "t")
        searchAetherItem?.keyEquivalentModifierMask = [.command, .option]
        navigateMenuItem.submenu?.addItem(NSMenuItem.separator())
        let prevTab = navigateMenuItem.submenu?.addItem(withTitle: "Previous Tab", action: #selector(MainWindowController.previousTab(_:)), keyEquivalent: "[")
        prevTab?.keyEquivalentModifierMask = [.command, .shift]
        let nextTab = navigateMenuItem.submenu?.addItem(withTitle: "Next Tab", action: #selector(MainWindowController.nextTab(_:)), keyEquivalent: "]")
        nextTab?.keyEquivalentModifierMask = [.command, .shift]
        mainMenu.addItem(navigateMenuItem)

        // ── View ──
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = NSMenu(title: "View")
        viewMenuItem.submenu?.addItem(withTitle: "Toggle File Browser", action: #selector(MainWindowController.toggleFileBrowser(_:)), keyEquivalent: "1")
        viewMenuItem.submenu?.addItem(withTitle: "Toggle Pythia", action: #selector(MainWindowController.togglePythia(_:)), keyEquivalent: "2")
        viewMenuItem.submenu?.addItem(withTitle: "Oracle Only", action: #selector(MainWindowController.toggleOracleOnly(_:)), keyEquivalent: "3")
        let aegisItem = viewMenuItem.submenu?.addItem(withTitle: "Aegis Mirror", action: #selector(MainWindowController.toggleAegis(_:)), keyEquivalent: "a")
        aegisItem?.keyEquivalentModifierMask = [.command, .shift]
        viewMenuItem.submenu?.addItem(NSMenuItem.separator())
        let softWrapItem = viewMenuItem.submenu?.addItem(withTitle: "Soft Wrap", action: #selector(MainWindowController.toggleWordWrap(_:)), keyEquivalent: "w")
        softWrapItem?.keyEquivalentModifierMask = [.control, .option]
        viewMenuItem.submenu?.addItem(withTitle: "Line Numbers", action: #selector(MainWindowController.toggleLineNumbers(_:)), keyEquivalent: "")
        viewMenuItem.submenu?.addItem(withTitle: "Wrap Column", action: #selector(MainWindowController.toggleWrapColumn(_:)), keyEquivalent: "")
        // Wrap Column Width presets
        let wrapColumnWidthMenu = NSMenu(title: "Wrap Column Width")
        for preset in EditorDisplaySettings.presets {
            let item = wrapColumnWidthMenu.addItem(withTitle: "\(preset)", action: #selector(MainWindowController.setWrapColumnWidth(_:)), keyEquivalent: "")
            item.representedObject = preset
        }
        wrapColumnWidthMenu.addItem(NSMenuItem.separator())
        wrapColumnWidthMenu.addItem(withTitle: "Other…", action: #selector(MainWindowController.setWrapColumnOther(_:)), keyEquivalent: "")
        let wrapWidthItem = NSMenuItem(title: "Wrap Column Width", action: nil, keyEquivalent: "")
        wrapWidthItem.submenu = wrapColumnWidthMenu
        viewMenuItem.submenu?.addItem(wrapWidthItem)
        viewMenuItem.submenu?.addItem(withTitle: "Highlight Current Line", action: #selector(MainWindowController.toggleHighlightCurrentLine(_:)), keyEquivalent: "")
        let invisiblesItem = viewMenuItem.submenu?.addItem(withTitle: "Show Invisibles", action: #selector(MainWindowController.toggleInvisibles(_:)), keyEquivalent: "i")
        invisiblesItem?.keyEquivalentModifierMask = [.control, .option]
        viewMenuItem.submenu?.addItem(NSMenuItem.separator())
        let biggerItem = NSMenuItem(title: "Bigger", action: #selector(AppDelegate.biggerFont), keyEquivalent: "+")
        biggerItem.keyEquivalentModifierMask = .command
        viewMenuItem.submenu?.addItem(biggerItem)
        let smallerItem = NSMenuItem(title: "Smaller", action: #selector(AppDelegate.smallerFont), keyEquivalent: "-")
        smallerItem.keyEquivalentModifierMask = .command
        viewMenuItem.submenu?.addItem(smallerItem)
        let resetItem = NSMenuItem(title: "Reset Size", action: #selector(AppDelegate.resetFontSize), keyEquivalent: "0")
        resetItem.keyEquivalentModifierMask = .command
        viewMenuItem.submenu?.addItem(resetItem)
        mainMenu.addItem(viewMenuItem)

        // ── Theme ──
        let themeMenuItem = NSMenuItem()
        themeMenuItem.submenu = NSMenu(title: "Theme")
        for (appearance, label) in [(ThemeAppearance.dark, "Dark"), (ThemeAppearance.light, "Light")] {
            let sectionItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let section = NSMenu(title: label)
            for (i, theme) in ThemeRegistry.shared.themes.enumerated()
                where theme.appearance == appearance {
                let item = NSMenuItem(title: theme.displayName, action: #selector(AppDelegate.selectTheme(_:)), keyEquivalent: "")
                item.tag = i
                item.state = (i == ThemeRegistry.shared.activeIndex) ? .on : .off
                section.addItem(item)
            }
            sectionItem.submenu = section
            themeMenuItem.submenu?.addItem(sectionItem)
        }
        themeMenuItem.submenu?.addItem(NSMenuItem.separator())
        themeMenuItem.submenu?.addItem(withTitle: "Next Theme", action: #selector(AppDelegate.nextTheme(_:)), keyEquivalent: "]")
        themeMenuItem.submenu?.addItem(withTitle: "Previous Theme", action: #selector(AppDelegate.previousTheme(_:)), keyEquivalent: "[")
        themeMenuItem.submenu?.addItem(NSMenuItem.separator())
        themeMenuItem.submenu?.addItem(withTitle: "Theme Settings…", action: #selector(AppDelegate.openThemeSettings(_:)), keyEquivalent: "")
        mainMenu.addItem(themeMenuItem)
        
        // ── Æther ──
        let aetherMenuItem = NSMenuItem()
        aetherMenuItem.submenu = NSMenu(title: "Æther")
        aetherMenuItem.submenu?.addItem(withTitle: "Start Ruby Daemon", action: #selector(AppDelegate.startRubyDaemon), keyEquivalent: "")
        aetherMenuItem.submenu?.addItem(withTitle: "Stop Ruby Daemon", action: #selector(AppDelegate.stopRubyDaemon), keyEquivalent: "")
        aetherMenuItem.submenu?.addItem(NSMenuItem.separator())
        aetherMenuItem.submenu?.addItem(withTitle: "Test Mnemosyne", action: #selector(AppDelegate.testMnemosyne), keyEquivalent: "")
        aetherMenuItem.submenu?.addItem(withTitle: "Test Aegis", action: #selector(AppDelegate.testAegis), keyEquivalent: "")
        aetherMenuItem.submenu?.addItem(NSMenuItem.separator())
        aetherMenuItem.submenu?.addItem(withTitle: "Daemon Status", action: #selector(AppDelegate.daemonStatus), keyEquivalent: "")
        aetherMenuItem.submenu?.addItem(NSMenuItem.separator())
        let debugItem = NSMenuItem(title: "Show Æther Debug", action: #selector(AppDelegate.toggleAetherDebug), keyEquivalent: "d")
        debugItem.keyEquivalentModifierMask = [.command, .shift]
        aetherMenuItem.submenu?.addItem(debugItem)
        mainMenu.addItem(aetherMenuItem)
        
        
        NSApp.mainMenu = mainMenu
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        ThemeRegistry.shared.activate(index: sender.tag)
        updateThemeMenu()
    }

    @objc private func nextTheme(_ sender: NSMenuItem) {
        ThemeRegistry.shared.next()
        updateThemeMenu()
    }

    @objc private func previousTheme(_ sender: NSMenuItem) {
        ThemeRegistry.shared.previous()
        updateThemeMenu()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        SettingsViewController.open(section: .newFile)
    }

    @objc private func openThemeSettings(_ sender: NSMenuItem) {
        SettingsViewController.open(section: .appearance)
    }

    @objc private func openProjectSettings(_ sender: NSMenuItem) {
        ProjectSettingsViewController.open()
    }

    /// Disable Project Settings when no folder/context is open (not in project
    /// mode) — the dialog itself also shows an empty state as a fallback.
    @MainActor @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openProjectSettings(_:)) {
            return AetherContext.shared.root != nil
        }
        return true
    }

    private func updateThemeMenu() {
        guard let themeMenu = NSApp.mainMenu?.item(withTitle: "Theme")?.submenu else { return }
        for item in themeMenu.items {
            // Theme items live one level deep under the Dark / Light sections.
            // Top-level items (Next/Previous/Settings, separators) carry tag 0
            // and must not receive the active-theme checkmark.
            guard let submenu = item.submenu else { continue }
            for subitem in submenu.items {
                subitem.state = (subitem.tag == ThemeRegistry.shared.activeIndex) ? .on : .off
            }
        }
    }

    // MARK: - Font Size

    @objc func biggerFont() {
        ThemeSettings.shared.fontSize = min(48, ThemeSettings.shared.fontSize + 1)
    }

    @objc func smallerFont() {
        ThemeSettings.shared.fontSize = max(6, ThemeSettings.shared.fontSize - 1)
    }

    @objc func resetFontSize() {
        ThemeSettings.shared.fontSize = 13
    }
    
    // MARK: - Æther Ruby Bridge
    
    @objc func startRubyDaemon() {
        NSLog("[AppDelegate] startRubyDaemon called")
        Task {
            NSLog("[AppDelegate] Inside Task, calling RubyBridge.shared.start()")
            do {
                try await RubyBridge.shared.start()
                NSLog("[AppDelegate] RubyBridge.start() succeeded")
                await MainActor.run {
                    showAlert(title: "Æther Daemon", message: "Ruby daemon started successfully")
                }
            } catch {
                NSLog("[AppDelegate] RubyBridge.start() failed: \(error)")
                await MainActor.run {
                    showAlert(title: "Error", message: "Failed to start daemon: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @objc func stopRubyDaemon() {
        RubyBridge.shared.stop()
        showAlert(title: "Æther Daemon", message: "Ruby daemon stopped")
    }
    
    @objc func testMnemosyne() {
        NSLog("[AppDelegate] testMnemosyne called")
        Task {
            do {
                NSLog("[AppDelegate] Starting daemon check...")
                // First ensure daemon is running
                if !RubyBridge.shared.isRunning {
                    NSLog("[AppDelegate] Daemon not running, starting...")
                    try await RubyBridge.shared.start()
                    NSLog("[AppDelegate] Daemon started")
                }
                
                NSLog("[AppDelegate] Sending remember...")
                // Store a test note
                let noteResult = try await RubyBridge.shared.remember(
                    content: "Test note from Swift at \(Date())",
                    tags: ["test", "swift", "aethercodex"],
                    links: []
                )
                NSLog("[AppDelegate] Remember result: \(noteResult ?? [:])")
                
                NSLog("[AppDelegate] Recalling notes...")
                // Recall notes
                let notes = try await RubyBridge.shared.recallNotes(query: "test", limit: 5)
                NSLog("[AppDelegate] Recalled \(notes.count) notes")
                
                await MainActor.run {
                    let notesText = notes.map { note in
                        guard let content = note["content"] as? String,
                              let id = note["id"] as? Int else { return "" }
                        return "[\(id)] \(content)"
                    }.joined(separator: "\n")
                    
                    let storedId = noteResult?["id"] as? Int ?? -1
                    showAlert(title: "Mnemosyne Test", message: "Stored note ID: \(storedId)\n\nRecall results:\n\(notesText)")
                }
            } catch {
                NSLog("[AppDelegate] Error: \(error)")
                await MainActor.run {
                    showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }
    
    @objc func testAegis() {
        Task {
            do {
                // First ensure daemon is running
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                
                // Update Aegis
                let updateResult = try await RubyBridge.shared.updateAegis(
                    summary: "Testing Aegis from Swift at \(Date())",
                    tags: ["swift", "test"]
                )
                
                // Get Aegis state
                let aegis = try await RubyBridge.shared.getAegis()
                
                await MainActor.run {
                    let summary = aegis?["summary"] as? String ?? "none"
                    let tags: [String] = {
                        if let arr = aegis?["tags"] as? [String] { return arr }
                        if let str = aegis?["tags"] as? String, !str.isEmpty { return str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                        return []
                    }()
                    showAlert(title: "Aegis Test", message: "Updated: \(updateResult ?? "failed")\n\nCurrent state:\nSummary: \(summary)\nTags: \(tags.joined(separator: ", "))")
                }
            } catch {
                await MainActor.run {
                    showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }
    
    @objc func toggleAetherDebug() {
        AetherDebugWindowController.shared.toggle()
    }

    @objc func daemonStatus() {
        let isRunning = RubyBridge.shared.isRunning
        showAlert(title: "Daemon Status", message: isRunning ? "Ruby daemon is running" : "Ruby daemon is stopped")
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}