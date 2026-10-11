# Syntax & Theme — Quick Reference

## The Five Stages

| # | Stage | Where | What |
|---|-------|-------|------|
| 1 | **Convert** | `Script/convert_themes.py` | `.tmTheme` → `.yml` + 7 universal anchors |
| 2 | **Load** | `ThemeLoader.swift:290-460` | `.yml` → `LoadedTheme` + parent inference |
| 3 | **Map** | `TreeSitterEngine.swift:637` | capture name → `TokenScope` enum |
| 4 | **Resolve** | `ThemeLoader.swift:356` | scope string → `TokenStyle` via cascade |
| 5 | **Render** | `SyntaxEngine.swift:327` | `TokenStyle` → `NSAttributedString` attributes |

## Cascade Walk

```
entity.name.class:
  plain → entity → entity.name → entity.name.class
  (merge at each step)
```

## Key Files

```
AetherCodex/App/
  SyntaxTheme.swift       — TokenScope (75 cases), TokenStyle, SyntaxTheme protocol
  ThemeLoader.swift       — YAML load, resolveStyle cascade, inferParentScopes
  SimpleYaml.swift        — Minimal YAML parser
  TreeSitterEngine.swift  — 14 grammars, CaptureScopeMapper
  SyntaxEngine.swift      — Orchestration, applyHighlighting
  SyntaxLoader.swift      — Heuristic fallback

AetherCodex/Resources/resources/
  Themes/*.yml            — 52 themes
  Syntax/queries/*.scm    — 14 tree-sitter highlight queries
  Syntax/heuristic.yml    — Regex fallback patterns

Script/
  convert_themes.py       — tmTheme → YAML converter
```

## Common Tasks

**Add a scope to hand-crafted themes**: edit `scopes:` in `.yml`, add `entityNameClass: "0xRRGGBB"` style entry.

**Add a tree-sitter capture mapping**: edit `CaptureScopeMapper.scope(for:)` in `TreeSitterEngine.swift:637`.

**Add a new TokenScope**: add case to `TokenScope` enum in `SyntaxTheme.swift:44`, add mapping in mapper, add to themes.

**Regenerate themes after converter change**: `python3 Script/convert_themes.py` per file, then `./bundle_app.sh`.

## Diagnostic Commands

```bash
# Count scopes in a theme
grep -c "^\s\+\w" AetherCodex/Resources/resources/Themes/theme.yml

# List all theme names
grep "^name:" AetherCodex/Resources/resources/Themes/*.yml

# Check for plain anchor (required)
grep "plain:" AetherCodex/Resources/resources/Themes/*.yml

# Build + deploy
swift build && ./bundle_app.sh
```
