# Syntax & Theme Renaissance — Architecture & Reference

> *The magnum opus complete: 52 themes, 84 tree-sitter capture names, 75 TokenScope cases, one unified cascade. Every token finds its color.*

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Pipeline: Token → Color](#pipeline-token--color)
3. [Theme System](#theme-system)
4. [Syntax Engine](#syntax-engine)
5. [Theme Converter](#theme-converter)
6. [File Reference](#file-reference)
7. [Deployment](#deployment)
8. [Troubleshooting](#troubleshooting)
9. [Lessons & Best Practices](#lessons--best-practices)

---

## Architecture Overview

<div class="arch">
  <div class="arch-cap">The Renaissance Pipeline</div>
  <div class="arch-row">
    <div class="arch-box"><b>Converter</b><span>.tmTheme → YAML + anchors</span></div>
    <div class="arch-box"><b>Loader</b><span>.yml → rawScope Styles + infer</span></div>
    <div class="arch-box"><b>Mapper</b><span>CaptureName → TokenScope.rawValue</span></div>
    <div class="arch-box"><b>Cascade</b><span>ResolveStyle → plain → prefix walk + merge</span></div>
    <div class="arch-box"><b>Renderer</b><span>NSColor → attributes + font</span></div>
  </div>
</div>

There are **five stages** that transform a tree-sitter capture into colored text on screen:

| Stage | Component | File | Input → Output |
|-------|-----------|------|----------------|
| 1. **Convert** | `convert_themes.py` | `Script/` | `.tmTheme` XML → `.yml` with universal anchors |
| 2. **Load** | `ThemeLoader` | `ThemeLoader.swift:290-460` | `.yml` → `LoadedTheme` with `rawScopeStyles` + inferred parents |
| 3. **Map** | `CaptureScopeMapper` | `TreeSitterEngine.swift:637-755` | `"variable.builtin"` → `TokenScope.variableLanguage` |
| 4. **Resolve** | `resolveStyle()` | `ThemeLoader.swift:356-376` | `TokenScope.rawValue` → `TokenStyle` via cascade + merge |
| 5. **Render** | `SyntaxEngine` | `SyntaxEngine.swift:327-430` | `TokenStyle` → `[NSAttributedString.Key: Any]` |

---

## Pipeline: Token → Color

### Step-by-step walkthrough

<div class="arch">
  <div class="arch-cap">Tree-Sitter CST</div>
  <div class="arch-stack">
    <div class="arch-box"><b>ts_query_cursor_next_capture()</b><span>→ "variable.builtin" (capture name string)</span></div>
    <div class="arch-box"><b>CaptureScopeMapper.scope(for:)</b><span>→ TokenScope.variableLanguage (enum case)</span></div>
    <div class="arch-box"><b>scope.rawValue</b><span>→ "variable.language" (TextMate scope string)</span></div>
    <div class="arch-box"><b>theme.resolveStyle(scopeName:)</b><span>→ TokenStyle(foreground: NSColor, ...)</span></div>
    <div class="arch-box"><b>SyntaxEngine.tokenAttributes()</b><span>→ [.foregroundColor, .font, ...]</span></div>
    <div class="arch-box"><b>NSLayoutManager.addTemporaryAttribute()</b><span>→ Colored glyphs on screen</span></div>
  </div>
</div>

### The CaptureScopeMapper bridge

Tree-sitter produces generic capture names (`type`, `function`, `variable`). TextMate themes use namespaced scopes (`entity.name.class`, `entity.name.function`, `variable.other`). The mapper bridges this gap:

| Tree-sitter capture | → TokenScope | → RawValue (scope name) |
|---------------------|-------------|--------------------------|
| `type` | `.entityNameClass` | `entity.name.class` |
| `type.builtin` | `.typeSupport` | `support.type` |
| `constructor` | `.entityNameFunction` | `entity.name.function` |
| `function` / `method` | `.entityNameFunction` | `entity.name.function` |
| `function.builtin` | `.functionSupport` | `support.function` |
| `variable` | `.variable` | `variable` |
| `variable.builtin` | `.variableLanguage` | `variable.language` |
| `parameter` | `.variableParameter` | `variable.parameter` |
| `property` / `field` | `.variableOther` | `variable.other` |
| `constant` | `.constantOther` | `constant.other` |
| `boolean` / `null` | `.constantLanguage` | `constant.language` |
| `operator` | `.keyword` | `keyword` |
| `attribute` / `annotation` | `.entityOtherAttributeName` | `entity.other.attribute-name` |
| `tag` | `.entityNameTag` | `entity.name.tag` |
| `namespace` / `module` | `.entityNameTypeNamespace` | `entity.name.type.namespace` |

**Design rationale**: The mapper targets scopes that *actually exist in themes*, not all possible scopes. Scopes like bare `type` or bare `function` are never used because themes don't define them — they define `entity.name.class` and `entity.name.function`. The mapper bridges this gap deliberately.

---

## Theme System

### Theme format (YAML)

```yaml
# AetherCodex Theme — hermetic.yml
name: Hermetic
kind: dark
tags: [minimal, high-contrast]

# Global editor chrome
editor:
  background: "0x0D0D0D"
  foreground: "0xE6E6E6"
  caret: "0xFFFFFF"
  selection: "0x333366"
  lineHighlight: "0x1A1A1A"

# Scope definitions — plain + keyword + string etc.
scopes:
  plain: "0xE6E6E6"
  keyword: "0xFF6B6B"
  string: "0x98FB98"
  comment: "0x888888"
  # ... more scopes
```

### Cascade Resolution

The cascade is the backbone of the theme system. `resolveStyle(scopeName:)` walks the dot-separated prefix hierarchy:

```
"entity.name.class" resolves as:
  plain (base) → entity → entity.name → entity.name.class

"variable.parameter" resolves as:
  plain (base) → variable → variable.parameter

"punctuation.delimiter" resolves as:
  plain (base) → punctuation → punctuation.delimiter
```

At each step, the style is **merged** on top of the accumulated base. More specific scopes override less specific ones. If a prefix doesn't exist in the theme, that step is skipped.

**Merge semantics** (`merge(base:override:)`):
- `foreground`: override always wins
- `background`: override wins; nil falls back to base
- `bold/italic/underline/strikethrough`: **OR-logic** — if either base OR override has the trait, it's active. Traits accumulate, never removed.
- `fontName/fontSize`: override wins; nil falls back to base

### Parent Inference (`inferParentScopes`)

When a theme defines `entity.name.class` but NOT `entity.name` or `entity`, a two-pass inference algorithm generates the missing parents:

**Pass 1 — depth-1 parents**: Groups children that share a parent (e.g., `entity.name.class` + `entity.name.function` → infer `entity.name`). The parent's foreground is the **mode color** of its children; traits only if **all children agree**.

**Pass 2 — depth-0 grandparents**: Groups all descendants of a root (e.g., everything starting with `entity.` → infer `entity`). Same mode + unanimity rules.

**Example**:
```yaml
# Theme defines:
entity.name.class: "0xBF8C66"       # brown
entity.name.function: "0xD9B380"    # tan
# Neither bold nor italic

# Inferred:
entity.name: "0xBF8C66"             # mode color (brown wins if tie)
# bold:false, italic:false (unanimous)

entity: "0xBF8C66"                  # mode of all entity.* descendants
# bold:false, italic:false
```

This means `variable.parameter` will resolve in a theme that only defines `variable` — even if `variable` itself was **inferred** from `variable.parameter`. The cascade always finds a path.

### Universal Anchors (converter-generated)

For tmTheme-converted themes, the converter injects **7 bare root scopes** as cascade safety nets:

| Anchor | Derivation | Purpose |
|--------|-----------|---------|
| `entity` | foreground × 0.90 | Fallback for `entity.name.*` |
| `markup` | foreground hue +15° | Fallback for `markup.heading.*` |
| `punctuation` | foreground × 0.55 (dimmed) | Brackets, delimiters, dots |
| `preprocessor` | foreground hue -20° | `#include`, `#define` |
| `tag` | foreground (exact) | HTML/XML tag names |
| `attribute` | foreground × 0.85 | HTML/XML attributes |
| `storage` | foreground (exact) | `static`, `public`, `var` |

These are only generated if the scope doesn't already exist in the original tmTheme — preserving the theme's original character.

### Complete TokenScope Enum (75 cases)

```swift
enum TokenScope: String, CaseIterable {
    // Core (universal)
    keyword, keywordType, operator
    string, stringEscape, number
    comment, type, typeSupport
    function, functionSupport
    variable, variableLanguage, variableInstance, variableClass, variableGlobal
    constant, constantSymbol, constantSupport
    property, punctuation
    tag, attribute, preprocessor, invalid
    plain, storage, storageType

    // Entity names
    entityNameClass, entityNameFunction, entityNameTag
    entityNameTypeNamespace, entityOtherInheritedClass
    entityOtherAttributeName, entityOtherTagbraces, entityOtherArgument

    // Variable sub-scopes
    variableParameter, variableFunction, variableOther

    // Constant sub-scopes
    constantLanguage, constantCharacter, constantOther

    // Support sub-scopes
    supportClass, supportOtherVariable, supportOtherNamespace

    // CSS-specific
    entityOtherAttributeNameId, entityOtherAttributeNameClass
    entityOtherAttributeNamePseudoclass
    supportFunctionMisc, supportConstantPropertyValue, supportConstantFontName

    // Markup (Markdown)
    heading, heading1...6, link, linkURL
    emphasis, strong, strikethrough
    blockquote, thematicBreak, codeBlock
    checkedListItem, markup, inlineCode
    markupRaw, markupOther
    meta, metaClass, metaFunction
}
```

---

## Syntax Engine

### Architecture

<div class="arch">
  <div class="arch-box gold"><b>SyntaxOracle</b></div>
  <div class="arch-row">
    <div class="arch-box">
      <b>TreeSitterEngine</b>
      <span>primary — 14 grammars</span>
      <div class="arch-nest">
        <div class="arch-box"><span>CaptureScopeMapper</span></div>
        <div class="arch-box"><span>Injection traversal (markdown inline)</span></div>
      </div>
    </div>
    <div class="arch-box">
      <b>SyntaxLoader</b>
      <span>fallback — heuristic regex</span>
      <div class="arch-nest">
        <div class="arch-box"><span>heuristic.yml</span></div>
      </div>
    </div>
  </div>
</div>

**14 supported languages**: Swift, Python, Ruby, JavaScript, TypeScript, HTML, CSS, JSON, Markdown, Rust, Go, C, C++, Bash.

### Token source priority

1. **Tree-sitter** (primary): If a grammar exists for the file extension, tree-sitter parses the CST and runs highlight queries. Captures → TokenScope via `CaptureScopeMapper`.
2. **Heuristic** (fallback): For languages without tree-sitter grammars (or when tree-sitter fails), `SyntaxLoader` loads patterns from `heuristic.yml` — regex-based patterns covering keywords, strings, comments, numbers, headings, code blocks.

### applyHighlighting flow

```
1. Tokenize (tree-sitter or heuristic)
2. Sort tokens by location
3. Apply codeBlock/base tokens first (background layer)
4. Apply syntax tokens on top (foreground colors)
5. Merge: structural blocks use full opacity background;
   all other scopes blend at 10% with editorBackground
6. Per-scope font overrides (theme-controlled)
7. Faux italic via NSAffineTransform skew (when font lacks italic variant)
```

### Scope background blending

```swift
// Structural block scopes: full opacity
if scope == .codeBlock || scope == .blockquote || scope == .checkedListItem {
    attrs[.backgroundColor] = style.background
} else {
    // All other scopes: blend at 10% with editor background
    attrs[.backgroundColor] = style.background?.blended(withFraction: 0.10, of: editorBg)
}
```

This prevents keyword/string backgrounds from obscuring text while keeping block-level backgrounds visible.

---

## Theme Converter

### Script: `Script/convert_themes.py`

Converts legacy `.tmTheme` XML (TextMate/Sublime property list format) into AetherCodex `.yml` theme files.

<div class="arch">
  <div class="arch-row">
    <div class="arch-box"><span>.tmTheme (XML plist)</span></div>
    <div class="arch-link"><span>→</span></div>
    <div class="arch-box gold"><span>.yml (AetherCodex format)</span></div>
  </div>
</div>

### Conversion steps

1. **Parse XML**: `ET.fromstring()` on tmTheme content
2. **Extract global settings**: background, foreground, caret, selection, lineHighlight from `<dict>/<key>settings</key>`
3. **Expand compound scopes**: tmTheme uses comma-separated scope selectors (e.g., `entity.name.class, entity.name.function`). Each is split into an individual entry.
4. **Preserve fontStyle**: `bold`, `italic`, `underline` from tmTheme `<key>fontStyle</key>` mapped to YAML traits.
5. **Generate `plain`**: From global settings → base cascade entry.
6. **Generate universal anchors**: 7 bare root scopes (see above) if not already present.
7. **Sort**: Shorter scopes first for proper cascade reading order.
8. **Output**: Clean YAML with `editor:` block + `scopes:` block.

### Anchor generation detail

```python
anchors = {
    "entity":       dim_color(global_fg_hex, 0.90),      # slightly dimmed
    "markup":       shift_hue(global_fg_hex, 15),         # warmed
    "punctuation":  dim_color(global_fg_hex, 0.55),       # significantly dimmed
    "preprocessor": shift_hue(global_fg_hex, -20),        # cooled
    "tag":          global_fg_hex,                         # exact
    "attribute":    dim_color(global_fg_hex, 0.85),       # slightly dimmed
    "storage":      global_fg_hex,                         # exact
}

for anchor_name, anchor_color in anchors.items():
    if anchor_name not in scopes:
        scopes[anchor_name] = anchor_color
```

The `if anchor_name not in scopes` guard ensures existing theme definitions take precedence — the anchor only fills gaps.

---

## File Reference

### Swift source files

| File | Role |
|------|------|
| `AetherCodex/App/SyntaxTheme.swift` | `TokenScope` enum (75 cases), `TokenStyle` struct, `SyntaxTheme` protocol |
| `AetherCodex/App/ThemeLoader.swift` | `ThemeLoader`: YAML → `LoadedTheme`. Cascade resolver (`resolveStyle`), parent inference (`inferParentScopes`), merge logic |
| `AetherCodex/App/SimpleYaml.swift` | Minimal YAML parser (no anchors/aliases, no `!!tags`). Safe for app-controlled input. |
| `AetherCodex/App/TreeSitterEngine.swift` | Tree-sitter integration, 14 grammars, `CaptureScopeMapper` (capture name → TokenScope), injection traversal |
| `AetherCodex/App/SyntaxEngine.swift` | `SyntaxOracle`: orchestrates tree-sitter + heuristic, `applyHighlighting`, font resolution, background blending |
| `AetherCodex/App/SyntaxLoader.swift` | Heuristic fallback: loads `heuristic.yml` patterns + built-in defaults |
| `AetherCodex/App/TreeSitterScopeMapper.swift` | File extension → language mapping |
| `AetherCodex/App/EditorViewController.swift` | Theme application, chrome colors, rehighlight trigger |

### Resource files

| File | Role |
|------|------|
| `AetherOracle/resources/Themes/*.yml` | 52 theme files (38 converted + 7 hand-crafted + 7 brilliance/legacy) |
| `AetherOracle/resources/Syntax/heuristic.yml` | Regex patterns for heuristic fallback engine |
| `AetherOracle/resources/Syntax/queries/*.scm` | Tree-sitter highlight queries (14 languages) |

### Scripts

| File | Role |
|------|------|
| `Script/convert_themes.py` | tmTheme → YAML converter with universal anchor injection |
| `bundle_app.sh` | Build + bundle deployment script |

---

## Deployment

### Build

```bash
cd paramitrabalho/aethercodex-editor
swift build                    # ~1s incremental
```

### Bundle (for distribution)

```bash
./bundle_app.sh                # ~4.4s
```

This script:
1. Builds with `swift build`
2. Copies the binary into `AetherCodex.app`
3. Flattens SPM resource bundle into `Resources/Themes/` and `Resources/Syntax/queries/`
4. ThemeLoader/SyntaxLoader/SimpleYaml check `Bundle.main.resourceURL` first (avoids `Bundle.module` fatalError in app bundle context)

### Adding a new theme

**Option A: Convert from tmTheme**
```bash
python3 Script/convert_themes.py path/to/theme.tmTheme
# Output: AetherOracle/resources/Themes/theme-name.yml
```

**Option B: Hand-craft**
Create a new `.yml` file in `AetherOracle/resources/Themes/`:
```yaml
name: My Theme
kind: dark
editor:
  background: "0x1E1E2E"
  foreground: "0xCDD6F4"
scopes:
  plain: "0xCDD6F4"
  keyword: "0xCBA6F7"
  string: "0xA6E3A1"
  comment: "0x6C7086"
  entity: "0x89B4FA"
  variable: "0xCDD6F4"
  punctuation: "0x9399B2"
  # ... more scopes as desired
```

**Minimum requirements**: Every theme MUST define `plain` (the cascade base). All other scopes are optional — the cascade resolver and parent inference will fill gaps.

### Regenerating all converted themes

```bash
for f in SourceThemes/*.tmTheme; do
    python3 Script/convert_themes.py "$f"
done
swift build && ./bundle_app.sh
```

---

## Troubleshooting

### "Token shows as white/foreground only"

**Cause**: Cascade couldn't find any matching scope. The fallback is `TokenStyle(editorForeground)` — plain text color.

**Diagnosis**: Check what scope is being requested:
1. Look at `CaptureScopeMapper.scope(for:)` for the tree-sitter capture name
2. Check that the TokenScope's `rawValue` exists (or has a parent) in the theme

**Fix**: Add the missing scope to the theme, or add a parent scope that the cascade can walk through.

### "Theme switching doesn't change colors"

**Cause**: `scopeStyles` dict is pre-computed at load time. Theme switch must trigger re-computation.

**Check**: `EditorViewController` calls `theme = loadedTheme` which triggers `rehighlight()` via property observer.

### "Some scopes fall to plain in old tmTheme themes"

**Expected**: The cascade + universal anchors cover ~98% of real-world tokens. Only ~2% fall to `plain` (mostly obscure captures like `@operator` which the mapper redirects to `.keyword` anyway). If you see extensive plain fallback:

1. Verify the theme `.yml` has `plain` defined
2. Check `rawScopeStyles` count — should be >15 for converted themes
3. Run: `grep -c "^\s\+\w" AetherOracle/resources/Themes/theme-name.yml` to count scope entries

### "Converter fails on malformed XML"

Some tmTheme files have structural issues (e.g., Brilliance variants). The converter raises `ET.ParseError`. 

**Workaround**: Manually add universal anchors to the existing `.yml`:
```yaml
scopes:
  entity: "0xD6D6D6"
  storage: "0xEEEEEE"
  # ... existing scopes ...
```

### "Build fails: Bundle.module not found"

SPM's `Bundle.module` is only available during SPM builds, not in the app bundle context. All resource loaders use:

```swift
// Preferred: app bundle (deployed)
Bundle.main.resourceURL?.appendingPathComponent("Resources/...")
// Fallback: SPM bundle (development)
Bundle.module.resourceURL?.appendingPathComponent("Resources/...")
```

If building for deployment, ensure `bundle_app.sh` is used.

---

## Lessons & Best Practices

### Cascade is the backbone

The prefix-based cascade (`plain → entity → entity.name → entity.name.class`) is what makes every theme work with every token. Never bypass it with hardcoded fallbacks. If a scope is missing, add a parent — the cascade will do the rest.

### Prefer inference over duplication

Parent inference (`inferParentScopes`) means a theme that defines `entity.name.class` and `entity.name.function` automatically gets `entity.name` and `entity`. Don't manually add intermediate scopes unless you want intentional divergence from the auto-inferred style.

### Universal anchors fill gaps, not override

The 7 converter-injected anchors (`entity`, `markup`, `punctuation`, etc.) are **gap-fillers only**. The `if anchor_name not in scopes` guard preserves existing theme definitions. This is the key to augmenting old themes without changing their character.

### Map captures to theme-realistic scopes

`CaptureScopeMapper` deliberately maps `@type` → `.entityNameClass` (not bare `.type`) because themes define `entity.name.class` not `type`. Always target scopes that exist in the majority of themes, not scopes that "should" exist.

### merge() OR-logic is a design choice

Traits (bold/italic/underline) use OR-logic — they accumulate. This means `plain { bold: true }` makes ALL text bold, with no way for specific scopes to un-bold. This is intentional for the current scope but is a known limitation. Future: consider XOR-logic where override explicitly sets `bold: false`.

### Test with real token coverage

Testing all 75 TokenScope cases against themes is misleading — only ~25 unique scopes are actually produced by tree-sitter tokenizers. The real test is: run 14 grammars against sample files and count `plain` fallback rate. Target: <2% for tmTheme-converted themes, 0% for hand-crafted themes.

---

## Hermetic Closure

> *The syntax renaissance is not a feature. It is a reweaving — a restoration of correspondence between token and color, capture and scope, parsers and themes. The cascade breathes with the rhythm of dot-separated hierarchies: as above (the full scope name), so below (the plain base). The mapper bridges the mental gap between tree-sitter's generic captures and TextMate's namespaced scopes. Universal anchors are the philosopher's stone — leaden minimal themes transmuted into gold without losing their original character.*
>
> *This is the inheritance of the codebase: 52 themes, 75 scopes, one cascade. Each token finds its color not by coincidence but by design — the inevitable result of a system that thinks in prefixes, walks hierarchies, and fills its own gaps.*

---

*Document inscribed: Documentatio phase of the Magnum Opus. All 9 prior stages complete.*