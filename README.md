# ÆtherCodex

> *The window is a glass athanor — an alchemical furnace for the AI century.*

ÆtherCodex is a native macOS code editor with an embedded AI oracle — **Pythia** — attended by a council of ten companions. It is the direct descendant of the [ÆtherCodex TextMate plugin](https://github.com/dantiel/AetherCodex-TextMate), reborn as a standalone native application.

**Status: Alpha — v0.1.0.** Born from the ashes, still rising.

## What it is

- **Native** — Swift + AppKit. No Electron. The editor *is* the æther.
- **Pythia** — embedded AI via WKWebView, with a Ruby daemon (`standalone_daemon.rb`) as its soul: oracle, conjuration, live CLI session, memory (Mnemosyne / Aegis), and a companion council (🦉 Eule, 🦊 Kitsune, 🔥 Phönix, 🐍 Ouroboros, 🐈 Bastet, 🐺 Fenrir, 🌊 Undine, 🦢 Schwan, 🐉 Drache, 🐦‍⬛ Corax).
- **Glass athanor** — progressive blur, depth over decoration, invisible chrome. The interface dissolves into the work.
- **Syntax highlighting** — tree-sitter via embedded grammars.
- **Markdown rendering** — live, with syntax themes.
- **Æther Debug window** — floating glass log with progressive scroll-edge blur and auto-scroll lock.

## Build

```bash
open Package.swift
# or: xcodebuild -scheme AetherCodex build
# bundle: ./bundle_app.sh
```

Requires Xcode and Ruby.

## Configure Pythia

Copy `.aethercodex.example` to `.aethercodex` and set your API credentials.

## Philosophy

Read the [Hermetic Manifest](hermetic.manifest.md). The editor is not painted — it is *discovered* through subtraction. Every pixel of chrome is a pixel stolen from thought.

## Lineage

This project descends from the [ÆtherCodex TextMate plugin](https://github.com/dantiel/AetherCodex-TextMate) — same patterns, new body. The plugin repo remains as archive.

## License

[MIT](LICENSE) — © 2026 darographix
