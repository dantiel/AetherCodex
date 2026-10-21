import AppKit
import Foundation

// MARK: - External Git Editor
//
// The diff surface can hand a file to the user's external Git editor — the same
// editor `git commit` would launch. Resolution order (first hit wins):
//   1. GeneralSettings.gitExternalEditor (explicit override, set in Settings)
//   2. `git config --get core.editor` (local via repoRoot, then global, then system)
//   3. $GIT_EDITOR, then $VISUAL, then $EDITOR
//
// The command may carry arguments (`code --wait`, `subl -w`); the file path is
// appended as the final argument. `--wait` is stripped because our intent is
// "open", not git's "edit-and-wait".

enum ExternalEditorResolver {

    /// The resolved editor command string (raw), or "" when nothing is detected.
    static func detectedCommand(repoRoot: URL?) -> String {
        let override = GeneralSettings.shared.gitExternalEditor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override
        }
        if let editor = gitConfigEditor(repoRoot: repoRoot) { return editor }
        for key in ["GIT_EDITOR", "VISUAL", "EDITOR"] {
            if let v = EnvironmentSettings.shared.value(forKey: key), !v.isEmpty { return v }
        }
        return ""
    }

    /// Friendly display name for a resolved command (falls back to the binary name).
    static func displayName(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "None detected" }
        let executable = (parseCommand(trimmed).executable as NSString).lastPathComponent.lowercased()
        switch executable {
        case "code": return "Visual Studio Code"
        case "subl", "sublime_text": return "Sublime Text"
        case "mate": return "TextMate"
        case "vim": return "Vim"
        case "nvim": return "Neovim"
        case "nano": return "nano"
        case "emacs": return "Emacs"
        case "idea": return "IntelliJ IDEA"
        case "pycharm": return "PyCharm"
        case "zed": return "Zed"
        case "cursor": return "Cursor"
        case "fleet": return "JetBrains Fleet"
        default: return (executable as NSString).lastPathComponent
        }
    }

    /// Open a file in the resolved editor. Falls back to the system default app
    /// (NSWorkspace) when no editor command resolves to a launchable binary.
    @discardableResult
    static func open(fileURL: URL, repoRoot: URL?) -> Bool {
        let command = detectedCommand(repoRoot: repoRoot)
        guard !command.isEmpty else {
            return NSWorkspace.shared.open(fileURL)
        }
        let parsed = parseCommand(command)
        guard let executablePath = resolveExecutablePath(parsed.executable) else {
            return NSWorkspace.shared.open(fileURL)
        }
        // Strip `--wait` — we open, we don't block for a commit message.
        var args = parsed.arguments.filter { $0 != "--wait" }
        args.append(fileURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        do {
            try process.run()
            return true
        } catch {
            return NSWorkspace.shared.open(fileURL)
        }
    }

    // MARK: Internals

    private static func gitConfigEditor(repoRoot: URL?) -> String? {
        let scopes: [[String]]
        if let root = repoRoot {
            scopes = [["-C", root.path, "config", "--get", "core.editor"],
                      ["config", "--global", "--get", "core.editor"],
                      ["config", "--system", "--get", "core.editor"]]
        } else {
            scopes = [["config", "--get", "core.editor"],
                      ["config", "--global", "--get", "core.editor"],
                      ["config", "--system", "--get", "core.editor"]]
        }
        for args in scopes {
            if let value = runGit(args)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func runGit(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Split a git editor command into (executable, leading arguments),
    /// honouring single/double quotes.
    private static func parseCommand(_ command: String) -> (executable: String, arguments: [String]) {
        let tokens = shellSplit(command.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = tokens.first else { return ("", []) }
        return (first, Array(tokens.dropFirst()))
    }

    /// Minimal shell-word splitter (single + double quotes, whitespace).
    private static func shellSplit(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false, inDouble = false
        for ch in input {
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch); hasToken = true }
            } else if inDouble {
                if ch == "\"" { inDouble = false } else { current.append(ch); hasToken = true }
            } else {
                switch ch {
                case "'": inSingle = true; hasToken = true
                case "\"": inDouble = true; hasToken = true
                case " ", "\t", "\n":
                    if hasToken { tokens.append(current); current = ""; hasToken = false }
                default: current.append(ch); hasToken = true
                }
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Resolve an executable name to an absolute path via PATH lookup.
    private static func resolveExecutablePath(_ executable: String) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        let pathEnv = EnvironmentSettings.shared.value(forKey: "PATH") ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathEnv.split(separator: ":") {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}