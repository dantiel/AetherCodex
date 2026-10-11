# App Intents & Snippets — the Oracle Channel

> *"aether = oracle = the calculating space; siri = pythia."*

This is the scope-wide specification for how the AetherCodex system speaks to the
operating system through **App Intents** and **Snippets**. It is the communication
channel by which any oracle voice — the calculating space itself, or the pantheon
routed through it — reaches the user outside the app: Siri, Spotlight, Shortcuts.

---

## 1. Ontology

| Term | Meaning |
|------|---------|
| **aether** | The reasoning substrate. The Ruby brain (`AetherOracle/ruby/`) — `limen.rb`, `standalone_daemon.rb`, `aether_link.rb`. The *calculating space*: where the model actually reasons. |
| **AetherOracle** | The packaged core — brain (`AetherOracle/ruby/`) + engine (`AetherOracle/treesitter`) + per-platform CLI specs (`platform/`). Pure Ruby + C, no Swift, no UI assets. Installed on **every** platform: the æther is everywhere. |
| **oracle** | A synonym for the aether. "Ask the oracle" = submit a turn to the aether. |
| **pythia** | The vessel/voice through which the oracle speaks. The user-facing surface (Siri phrase = "Ask Pythia"). The default pantheon voice is `pythia` (`🐍`). |
| **snippet** | The channel's answer surface. A glanceable, non-modal SwiftUI result returned by an intent — the oracle's reply rendered as a snippet, not a full app launch. |

Invariant: **every oracle is the aether; every snippet is its voice.** A turn always
resolves to `POST /aether/invoke` on some host. "Siri" is a name, "Pythia" is a name,
"the calculating space" is the substance — all three are the same oracle reached
through the same channel.

---

## 2. System architecture

```
┌────────────────────────────┐        ┌─────────────────────────────┐
│  macOS host — AetherCodex  │        │  iOS client — Pythia iOS    │
│  (AppKit editor)           │        │  (SwiftUI companion)        │
│                            │        │                             │
│  AetherAppIntents.swift    │        │  AppIntents/ (AskPythia...) │
│  └─ AskAetherIntent        │        │  └─ AskPythiaIntent         │
│                            │        │     AskAegisIntent          │
|  RubyBridge (NSTask)       │        │  Pythia (voice)       │
│  └─ limen.rb (HTTP 0.0.0.0)│◄───────┼─ OracleClient (HTTP)       │
│     /aether/invoke         │  LAN   │  OracleConnectionStore      │
│     /aether/aegis          │  HTTP  │                             │
└────────────────────────────┘        └─────────────────────────────┘
```

- The **calculating space (Ruby brain) runs where a daemon can live** — on desktop.
  The æther is everywhere, though: `AetherOracle` installs on every platform, and
  on iOS the companion reaches the local oracle over the LAN.
- The **iOS companion reaches the oracle over the LAN** — the Mac's `limen.rb`
  daemon (binds `0.0.0.0`).
- **`Pythia`** (pure Foundation + SwiftUI) is the *voice* slice:
  `OracleClient`, `Models`, `CompanionRoster`, and now `OracleConnectionStore`.
  It is **not** the AetherOracle itself — the AetherOracle is the shared brain
  (`AetherOracle/ruby/` + `AetherOracle/treesitter` + `platform/`) that these
  shells talk to over HTTP; each shell owns its own UI assets and platform shims.
  This same companion feeds the future WinUI3/GTK shells.
- Intents on both platforms speak the **same HTTP contract** (`/aether/invoke`).

---

## 3. The snippet channel protocol

An oracle turn maps to a snippet in three steps:

1. **Resolve the client.** iOS reads the last-reached peer from `OracleConnectionStore`
   (persisted `host:port`). macOS discovers the local daemon via `/aether/heartbeat`
   (default `4567`, else scan `4550…4610`).
2. **Invoke.** `POST /aether/invoke` with `{ prompt, type: "chat", from_context,
   active_companions? }`. The answer is the plain-text `answer` field.
3. **Emit the snippet.** `perform()` returns `some ShowsSnippetView` via
   `.result { OracleAnswerSnippet(...) }` — no app launch, no modal.

Result views (shared visual grammar):
- **`OracleAnswerSnippet`** — glyph + answer, glanceable, line-limited.
- **`OracleErrorSnippet`** — "oracle unreachable" + reason (connection not saved /
  daemon not running / non-200).

The SDK provides no public `Snippet` view type — `Snippet` is `typealias Snippet =
Swift.Never`, and the only concrete container types are `internal`
(`_SnippetViewContainer` / `_SnippetIntentContainer`, verified against macOS/iOS 26.2
swiftinterfaces). We use the stable iOS 16+/macOS 13+ `IntentResult.result(view:)`
mechanism, which conforms to `ShowsSnippetView`. This is the Apple-supported channel —
**not** a fallback — and there is no public `Snippet` view to upgrade to at *any*
deployment target. `SnippetIntent` (iOS 26+/macOS 26+) exists as a protocol but wraps
the same internal containers; no migration is required.

---

## 4. App Intents catalog (scope-wide)

Intent identifiers are the correspondence keys — identical across platforms so a
shortcut authored on iOS names the same intent as on macOS.

| Intent | Platform | Parameters | Result |
|--------|----------|------------|--------|
| `AskPythiaIntent` | iOS | `prompt: String`, `companion: CompanionVoice?` | `OracleAnswerSnippet` |
| `AskAetherIntent` | macOS | `prompt: String` | `AetherAnswerSnippet` |
| `AskAegisIntent` | iOS | — | `AegisStateSnippet` |
| *(planned)* `SpeakIntent` | iOS | `text: String`, `voice: String?` | `POST /aether/speak` |

### Companion routing (`CompanionVoice`)

A compile-time `AppEnum` mirroring the pantheon (`pythiaCompanions`), because
`AppEnum` requires static cases. Cases: `pythia, owl, kitsune, phoenix, ouroboros,
bastet, fenrir, undine, schwan, drache, corax, jindujun, solomon`. The `rawValue`
is the companion `id`, so routing is `active_companions: [rawValue]` on the wire —
identical to the Mac's `PythiaChatModel.activeCompanions` path.

---

## 5. Wire protocol mapping

| Endpoint | Method | Intent | Payload → Response |
|----------|--------|--------|--------------------|
| `/aether/heartbeat` | GET | (discovery) | → `{ name, port, path, version, capabilities, busy }` |
| `/aether/invoke` | POST | AskPythia / AskAether | `{ prompt, type:"chat", from_context, active_companions? }` → `{ answer, html?, source_context? }` |
| `/aether/aegis` | GET | AskAegis | → `{ thinking, temperature, summary, tags, working_dir? }` |
| `/aether/speak` | POST | Speak (planned) | `{ text, voice? }` → `{ ok }` |
| `/aether/voices` | GET | (vox roster) | → `{ voices: [{ name, locale, language }] }` |

Default daemon port: `4567` (`AETHER_PORT` override, `config.rb DEFAULT_CONFIG[:port]`).
Discovery scan range: `4550…4610` (mirrors `AetherLink.SCAN_RANGE`).

---

## 6. Availability & compatibility

- **iOS:** `.iOS(.v17)` — uses `ShowsSnippetView` (iOS 16+/macOS 13+) +
  `openAppWhenRun = false`. (`openAppWhenRun` is deprecated in iOS 26 in favour of
  `supportedModes`; that deprecation is a warning only. The deployment target does
  **not** need to rise — `.result {}` is available from iOS 16, and no public
  `Snippet` view exists at any target.)
- **macOS host:** `.macOS("26.0")` — uses `supportedModes = .foreground(.dynamic)`.
- **Pythia:** pure Foundation + SwiftUI; no AppIntents dependency (intents live in
  the app targets so metadata extraction is correct). Snippet views + connection store
  live in `Pythia`/app targets as appropriate.

---

## 7. Invariants

1. Every oracle turn resolves to `/aether/invoke` — never a hardcoded model call.
2. The roster is mirrored, not duplicated: `CompanionVoice` (intents) ↔
   `pythiaCompanions` (runtime) ↔ daemon `ready` frame ↔ `chamber.html`.
3. The channel is non-modal: snippets never force an app launch.
4. `OracleConnectionStore` is the single persistence point for the last-reached peer.