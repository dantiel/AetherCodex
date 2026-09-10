# ÆtherCodex — Hermetic Native Editor

> *"Precision in code plane mirrors precision in astral plane."*

Native macOS editor with embedded AI oracle — a liminal bridge between code and the arcane.

## Quick Start

```bash
swift build && .build/debug/AetherCodex
```

Requires: **macOS 26 (Tahoe)**, Swift 5.9+, Xcode Command Line Tools.

## Architecture

```
AetherCodex (native SwiftUI/AppKit hybrid)
├── Editor            NSTextView-based code editor (AppKit surface)
├── Sidebar           FileBrowserScrollContent — file tree + PathBreadcrumbHeader (SwiftUI)
├── Pythia            PythiaPanel — pure SwiftUI chat (companions, streaming, tools)
└── RubyBridge        singleton — framed JSON protocol over pipes to Ruby/standalone_daemon.rb
```

All chrome (top bar, sidebar, Pythia pane) is expressed in SwiftUI via the
macOS 26 `safeAreaBar(edge:)` / `.scrollEdgeEffectStyle` / `.glassEffect` APIs.
The only AppKit bridge is `AppKitViewHost` (`NSViewRepresentable`) hosting the
editor surface and the sidebar container.

## Files

| Path | Role |
|------|------|
| `Package.swift` | SPM manifest, macOS .v13, swift-tools-version 5.9 |
| `AetherCodex/App/AppDelegate.swift` | `@main` entry, menu bar, Ruby daemon lifecycle |
| `AetherCodex/App/MainWindowController.swift` | Window + `EditorContainerView` host |
| `AetherCodex/App/SafeAreaBarHost.swift` | `EditorContainerView`, `safeAreaBar` chrome, `AppKitViewHost` |
| `AetherCodex/App/EditorViewController.swift` | NSTextView editor + AppKit surface |
| `AetherCodex/App/FileBrowserViewController.swift` | Sidebar + `PathBreadcrumbHeader` (glass breadcrumb) |
| `AetherCodex/App/PythiaPanel.swift` | Pure SwiftUI Pythia (`PythiaChatModel` + `PythiaPanel`) |
| `AetherCodex/Bridge/RubyBridge.swift` | Singleton for Ruby daemon interop |
| `Ruby/` | Ruby backend daemon (`standalone_daemon.rb`) |
| `docs/phase-iii-glass-breadcrumb-swiftui-pythia.md` | Phase III architecture + maintenance |
| `docs/phase-x-companion-omnipresence-riss-makro.md` | Companion-Omnipräsenz + Riss-Makro (Task #17) |
| `docs/phase-xi-flash-neufenser-aether-debug.md` | Flash-AI-Neufenser + Æther-Debug-Fenster (Task #18) |

## Build

```bash
swift build                          # Debug
swift build -c release               # Release optimized
./bundle_app.sh                      # Bundle into AetherCodex.app
open AetherCodex.app                 # Launch
```

## Roadmap (Hermetic Rhythm)

**Scaffold → Bridge → Polish → Ship**

1. ✅ Ruby daemon bridged (framed JSON protocol)
2. ✅ Syntax highlighting, line numbers, themes
3. ✅ Single-pane glass architecture (`docs/single-pane-architecture.md`)
4. ✅ Phase III: glass breadcrumb nav + pure SwiftUI Pythia (`docs/phase-iii-glass-breadcrumb-swiftui-pythia.md`)
5. ⬜ Inline terminal / REPL (vision state 4)
6. ⬜ Distraction-free quick peek polish