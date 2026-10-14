# The Architecture — One Oracle, Many Shells

> *One oracle, many voices. Install the core on any OS and that OS becomes an Aether OS.*

## The invariant

AetherCodex is the native macOS face of a larger system. The brain is not baked
into the editor — it lives in **AetherOracle**, a portable **RubyGem**. Install
that gem on any machine and it becomes an *Aether OS*: the same reasoning
substrate, the same memory, the same council, everywhere.

There is **one oracle**; **Pythia** is its voice. Every turn resolves to
`POST /aether/invoke` on some host that carries the core. There is no
client/server split — only the aether, and the shells that open onto it.

## The layers

<div class="arch">
  <div class="arch-cap">Native shells — the surfaces</div>
  <div class="arch-row">
    <div class="arch-box"><b>macOS</b><span>SwiftUI + AppKit</span></div>
    <div class="arch-box"><b>iOS</b><span>Pythia companion</span></div>
    <div class="arch-box"><b>Windows</b><span>C# .NET8 · WPF</span></div>
    <div class="arch-box"><b>Linux</b><span>GTK (spec)</span></div>
  </div>
  <div class="arch-wire"><span>POST /aether/invoke · protocol.md v1</span></div>
  <div class="arch-row">
    <div class="arch-box gold"><b>AetherOracle</b><span>the shared core — a RubyGem</span></div>
  </div>
</div>

## The core (AetherOracle)

A single gem, two tiers:

| Tier | Contents | Needs |
|------|----------|-------|
| **Brain tier** | `ask`, `server`, `config`, `task`, `logs`, `repl` — the daemon, the oracle, Mnemosyne, the instrumentarium | the brain gems (auto-installed) |
| **Link tier** | `peers`, `heartbeat`, `invoke` — pure Ruby stdlib | nothing but Ruby |

The link tier is the **aetherlink surface**: a minimal box with only Ruby can
reach the brain on a Mac over the same wire contract. This is how iOS reaches the
oracle — there is **no daemon on iOS**; the companion finds a peer's daemon over
the LAN.

Installing the gem registers **seven aliases**, all the same aether:

```
aetheroracle · aether · oracle · oracleaether · ae · aero · orae
```

## The daemon

The brain's running form is `ruby/standalone_daemon.rb`. AetherOracle owns the
**implementation** and the per-OS **lifecycle shims**
(`platform/{darwin,ios,windows,linux}`); the native shells own the **policy** —
when to start, when to stop, how to respond to a crash. On macOS the editor
spawns the daemon as a child `NSTask`; Windows and Linux do the equivalent; iOS
reports `canRunDaemon == false`.

## The resources

The visual grammar is shared data, not macOS-only assets:

- `resources/Themes` — YAML themes (the syntax renaissance)
- `resources/Syntax` — TextMate grammars + tree-sitter queries
- `resources/Fonts` — the typography of the athanor
- `treesitter/` — the C tree-sitter engine + grammars (portable C, used by SwiftPM)

## The projects

- **AetherCodex** (this site) — the native macOS editor, a SwiftUI App lifecycle.
- **AetherOracle** — the shared core. [Source](https://github.com/dantiel/AetherOracle) · [Site](https://dantiel.github.io/AetherOracle/).
- **AetherCodex · Windows** — the Windows shell (C# / .NET 8 / WPF), the Ruby daemon as its soul.
- **iOS · Linux** — the companion and the GTK shell, forthcoming.