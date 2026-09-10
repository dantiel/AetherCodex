# Theme import and decoration

Run `python3 Script/convert_themes.py --force` to regenerate installed TextMate
themes, or append `--theme=magicwb-amiga` for one family. The Ruby entry point
delegates to the same implementation. Test with `python3 Script/test_convert_themes.py`.

- Personal bundles take precedence over managed copies. Within that priority,
  the version with more scopes wins.
- Native syntax and markup styles are retained. Missing markup styles are
  derived from the palette. RGBA uses TextMate's RRGGBBAA order.
- Explicit light/dark appearance takes precedence over RGB brightness. Alpha
  editor backgrounds are composited against that appearance's base surface.
- `sourceEditorBackground` and `sourceRulerBackground` preserve original colors.
  The gutter's RGB becomes a stable material tint shared by the sidebar section.
- The floating sheet has a separate background. Its accent comes first from a
  chromatic gutter selection or editor selection, then from syntax colors.
  Generated text colors target 4.5:1 contrast and accents 3:1 on the sheet's
  nominal color. Backdrop compositing can change the final displayed contrast.
- The runtime applies the section tint at 86% over material. Sheet tint uses
  `sidebarBackgroundOpacity`. This keeps the two surfaces visually distinct.
- `--force` rewrites scopes and derived chrome; legacy manually adjusted effect
  parameters are retained. Keep a snapshot before regeneration if those scopes
  contain local edits. The source TextMate bundles are never modified.

CoffeeScript, LitCoffee, Haml, CoffeeHaml, Chaml and Lithaml have dedicated lexical
rules in `TemplateSyntaxEngine`. These are not a full TextMate/Oniguruma grammar
runtime. HTML and other supported languages continue to use Tree-sitter.
