import Cocoa

/// Command target for the SwiftUI menu (`AetherCommands`).
///
/// This is what remains of the old `AppDelegate` once SwiftUI took over the
/// application lifecycle: the action methods the menu invokes, nothing more.
/// It is deliberately *not* an `NSApplicationDelegate`.
///
/// Main-actor isolated because that is where it runs and where the scene router
/// it drives lives — the menu is main-thread by construction.
@MainActor
final class AppActions {

    // MARK: - File

    /// Open a file into the editor. The shell observes `.openFileInEditor`, so
    /// this needs no window reference of its own.
    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            NotificationCenter.default.post(name: .openFileInEditor, object: url)
        }
    }

    // MARK: - Settings

    func openSettings() {
        AppScene.shared.openSettings(section: .newFile)
    }

    func openThemeSettings() {
        AppScene.shared.openSettings(section: .appearance)
    }

    func openProjectSettings() {
        AppScene.shared.openProjectSettings()
    }

    // MARK: - Theme

    func selectTheme(_ index: Int) {
        ThemeRegistry.shared.activate(index: index)
    }

    func nextTheme() {
        ThemeRegistry.shared.next()
    }

    func previousTheme() {
        ThemeRegistry.shared.previous()
    }

    // MARK: - Font Size

    func biggerFont() {
        ThemeSettings.shared.fontSize = min(48, ThemeSettings.shared.fontSize + 1)
    }

    func smallerFont() {
        ThemeSettings.shared.fontSize = max(6, ThemeSettings.shared.fontSize - 1)
    }

    func resetFontSize() {
        ThemeSettings.shared.fontSize = 13
    }

    // MARK: - Æther Ruby Bridge

    func startRubyDaemon() {
        Task {
            do {
                try await RubyBridge.shared.start()
                await MainActor.run {
                    showAlert(title: "Æther Daemon", message: "Ruby daemon started successfully")
                }
            } catch {
                await MainActor.run {
                    showAlert(title: "Error", message: "Failed to start daemon: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRubyDaemon() {
        RubyBridge.shared.stop()
        showAlert(title: "Æther Daemon", message: "Ruby daemon stopped")
    }

    func testMnemosyne() {
        Task {
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                let noteResult = try await RubyBridge.shared.remember(
                    content: "Test note from Swift at \(Date())",
                    tags: ["test", "swift", "aethercodex"],
                    links: []
                )
                let notes = try await RubyBridge.shared.recallNotes(query: "test", limit: 5)
                await MainActor.run {
                    let notesText = notes.map { note in
                        guard let content = note["content"] as? String,
                              let id = note["id"] as? Int else { return "" }
                        return "[\(id)] \(content)"
                    }.joined(separator: "\n")
                    let storedId = noteResult?["id"] as? Int ?? -1
                    showAlert(title: "Mnemosyne Test",
                              message: "Stored note ID: \(storedId)\n\nRecall results:\n\(notesText)")
                }
            } catch {
                await MainActor.run {
                    showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    func testAegis() {
        Task {
            do {
                if !RubyBridge.shared.isRunning {
                    try await RubyBridge.shared.start()
                }
                let updateResult = try await RubyBridge.shared.updateAegis(
                    summary: "Testing Aegis from Swift at \(Date())",
                    tags: ["swift", "test"]
                )
                let aegis = try await RubyBridge.shared.getAegis()
                await MainActor.run {
                    let summary = aegis?["summary"] as? String ?? "none"
                    let tags: [String] = {
                        if let arr = aegis?["tags"] as? [String] { return arr }
                        if let str = aegis?["tags"] as? String, !str.isEmpty {
                            return str.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        }
                        return []
                    }()
                    showAlert(title: "Aegis Test",
                              message: "Updated: \(updateResult ?? "failed")\n\nCurrent state:\nSummary: \(summary)\nTags: \(tags.joined(separator: ", "))")
                }
            } catch {
                await MainActor.run {
                    showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    func toggleAetherDebug() {
        AppScene.shared.toggleDebugLog()
    }

    func daemonStatus() {
        let isRunning = RubyBridge.shared.isRunning
        showAlert(title: "Daemon Status",
                  message: isRunning ? "Ruby daemon is running" : "Ruby daemon is stopped")
    }

    // MARK: - Ægis Shield

    /// Reveal the Ægis — the shield that holds the system privileges so the
    /// editor never has to re-prompt across rebuilds.
    func openAegisShield() {
        AegisClient.shared.openShield()
    }

    /// Ask the shield to reflect the light of the screen, then save the result
    /// to ~/Pictures/AetherCodex and reveal it in Finder.
    func captureScreenViaAegis() {
        Task {
            let (data, error) = await AegisClient.shared.captureScreen()
            await MainActor.run {
                guard let data, let image = NSImage(data: data) else {
                    showAlert(title: "Ægis", message: error ?? "The shield returned no image.")
                    return
                }
                let dir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Pictures/AetherCodex", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = Self.screenStampFormatter.string(from: Date())
                let url = dir.appendingPathComponent("AetherScreen-\(stamp).png")
                do {
                    try data.write(to: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    showAlert(title: "Ægis", message: "Captured \(image.size.width.rounded())×\(image.size.height.rounded()) but could not save: \(error.localizedDescription)")
                }
            }
        }
    }

    private static let screenStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}