# Tool-Result Wire Protocol — Ruby ⇄ Swift

> *The full result reaches the model; the echo reaches the glass. One path carries meaning, the other carries presence.*

## Purpose

Instrumenta tool calls produce a result that travels **two distinct routes**:

1. **The model route** — the complete, lossless result (via the `tool` message).
2. **The UI route** — a compact, human-readable *echo* streamed to the Pythia panel
   as a live status before the final answer is composed.

This document pins the contract between the Ruby oracle and the Swift file-mirror
so that both routes stay truthful and neither leaks noise into the other.

## The Ruby side — `ui_preview`

Location: `Ruby/oracle/artificer.rb` (class method, inside the `class << self` block).

```ruby
def ui_preview(result, limit = 4000, name: nil)
  # read_file behält seine Struktur, damit der Swift-Datei-Spiegel Pfad/Range/Inhalt
  # rendern kann; andere content-tragende Ergebnisse bleiben ein kompaktes Echo.
  return result if name&.to_s == 'read_file' && result.is_a?(Hash)

  text = if result.is_a?(Hash)
           (result[:content] || result['content'] || result.to_json).to_s
         else
           result.to_s
         end
  text.truncate(limit)
end
```

### Contract

| Input | Behaviour |
|-------|-----------|
| `name == 'read_file'` **and** `result` is a `Hash` | **Pass-through** — the full structure (`path`, `range`, `content`, …) is returned untouched so the Swift file mirror can decode and render it. |
| Any other `Hash` result | Collapsed to `result[:content] \|\| result['content'] \|\| result.to_json`, truncated to `limit` (4000 chars). |
| Non-`Hash` result | `result.to_s`, truncated to `limit`. |

### Invariants

- `name` may arrive as a `String` or a `Symbol`; `name&.to_s` normalises both.
- `limit` is a **positional** argument that precedes the `name:` keyword argument.
  Ruby forbids a keyword argument before a positional one — the signature is
  `(result, limit = 4000, name: nil)`, never `(result, name: nil, limit = 4000)`.
- The preview is *cosmetic only*. The model never consumes it; truncation here
  cannot lose information that matters to the LLM.

### Call sites

Both `execute_standard` and `execute_fallback` emit the echo with the tool name:

```ruby
sink&.send_status 'tool_completed', {
  name:, execution_time: exec_time,
  result: ui_preview(safe_result, name: name)
}
```

The `sink` is the status stream (`stream` or `HorologiumAeternum`), which re-frames
the payload for `RubyBridge` and ultimately `PythiaPanel`.

## The Swift side — the file mirror

Location: `AetherCodex/App/FileInstrumentViews.swift`.

### Decoding

- `ReadFileResult` decodes only `content` / `error` (`Decodable`). The `path` is
  **not** carried in the result — it is recovered from the call arguments
  (`args?.path ?? ""`), which is why the Ruby pass-through preserves the full hash
  rather than collapsing it to `content` alone.
- `PatchFileResult` mirrors the same shape (`ok` / error / diff statistics).

### Rendering

- Both the `ReadFileView` and `PatchFileView` headers derive their subtitle from
  the file argument: `(path as NSString).lastPathComponent` — a non-optional
  `String` with a `?? ""` fallback, so the `as NSString` cast cannot crash.
- The done-card is the minimal `✓ ok` — no prose, per the hermetic *subtraction
  over addition* discipline.

## Flow diagram

```
Ruby instrumenta call
   └─ safe_encode(exec_result)          → full result  → model (tool message)
   └─ ui_preview(safe_result, name:)    → live echo    → sink → RubyBridge
                                                                   → PythiaPanel
                                                                       → FileInstrumentViews
```

## Maintenance notes

- If a new tool result needs **structural** rendering in Swift (not just a text
  echo), extend the `ui_preview` guard with its `name` rather than collapsing it,
  and add a matching `Decodable` struct in `FileInstrumentViews.swift`.
- Never reorder `ui_preview`'s arguments — keyword-before-positional is a Ruby
  syntax error.
- Verify with `ruby -c Ruby/oracle/artificer.rb` after any signature change.
